import 'dart:async';
import 'dart:convert';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Transport metadata only. Domain navigation remains in the existing router.
class PushNotificationTap {
  const PushNotificationTap({
    required this.notificationId,
    required this.userId,
  });
  final String notificationId;
  final String userId;

  static PushNotificationTap? fromData(Map<String, dynamic> data) {
    final id = data['notification_id'];
    final user = data['user_id'];
    if (id is! String ||
        id.isEmpty ||
        id.length > 128 ||
        user is! String ||
        user.isEmpty ||
        user.length > 128) {
      return null;
    }
    return PushNotificationTap(notificationId: id, userId: user);
  }

  String get key => '$userId:$notificationId';
  String toPayload() =>
      jsonEncode({'notification_id': notificationId, 'user_id': userId});
}

/// Stable across processes; Dart String.hashCode is deliberately not used.
int pushNotificationId(String value) {
  var hash = 0x811c9dc5;
  for (final byte in utf8.encode(value)) {
    hash = ((hash ^ byte) * 0x01000193) & 0xffffffff;
  }
  return hash & 0x7fffffff;
}

abstract interface class PushNotificationService {
  bool get isSupported;
  Stream<String> get tokenChanges;
  Stream<PushNotificationTap> get taps;
  Future<void> start(String userId);
  Future<bool> requestPermission();
  Future<bool> hasPermission();
  Future<String?> getToken();
  void setForegroundEnabled(bool enabled);
  Future<void> stop({bool invalidateToken = false});
  Future<void> dispose();
}

class FirebasePushNotificationService implements PushNotificationService {
  FirebasePushNotificationService();
  static const channelId = 'skilltrack_project_notifications';
  static bool get supportsCurrentPlatform =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  final _local = FlutterLocalNotificationsPlugin();
  final _tokens = StreamController<String>.broadcast();
  final _taps = StreamController<PushNotificationTap>.broadcast();
  final _shown = <String>{};
  final _opened = <String>{};
  StreamSubscription<String>? _tokenSubscription;
  StreamSubscription<RemoteMessage>? _messageSubscription, _openSubscription;
  FirebaseMessaging get _messaging => FirebaseMessaging.instance;
  Future<void>? _starting;
  bool _localInitialized = false, _initialChecked = false, _enabled = false;
  bool _disposed = false;
  bool _started = false;
  bool _invalidationPending = false;
  int _version = 0;
  String? _userId;

  @override
  bool get isSupported => supportsCurrentPlatform;
  @override
  Stream<String> get tokenChanges => _tokens.stream;
  @override
  Stream<PushNotificationTap> get taps => _taps.stream;

  bool _remember(Set<String> entries, String key) {
    if (!entries.add(key)) return false;
    if (entries.length > 256) entries.remove(entries.first);
    return true;
  }

  void _open(PushNotificationTap? tap) {
    if (_disposed ||
        tap == null ||
        tap.userId != _userId ||
        !_remember(_opened, tap.key)) {
      return;
    }
    _taps.add(tap);
  }

  void _openLocal(String? payload) {
    if (payload == null) return;
    try {
      final data = jsonDecode(payload);
      if (data is Map<String, dynamic>) {
        _open(PushNotificationTap.fromData(data));
      }
    } catch (_) {
      // Ignore malformed or obsolete local-notification payloads.
    }
  }

  @override
  Future<void> start(String userId) async {
    if (_disposed || !isSupported) return;
    if (_starting != null) await _starting;
    if (_disposed || (_userId == userId && _started)) return;
    final starting = _start(userId);
    _starting = starting;
    try {
      await starting;
    } finally {
      if (identical(_starting, starting)) _starting = null;
    }
  }

  Future<void> _start(String userId) async {
    await stop();
    if (_invalidationPending) {
      throw StateError('Unable to reset push registration. Please try again.');
    }
    final version = ++_version;
    _userId = userId;
    if (!_localInitialized) {
      await _local.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        ),
        onDidReceiveNotificationResponse: (response) =>
            _openLocal(response.payload),
      );
      await _local
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.createNotificationChannel(
            const AndroidNotificationChannel(
              channelId,
              'Project notifications',
              description: 'Task alerts, deadlines and learning resources.',
              importance: Importance.high,
            ),
          );
      _localInitialized = true;
    }
    if (_disposed || version != _version) return;
    // Keep registration tokens for the explicitly requested HTTP v1 message.token
    // contract. The SDK replacement emits FIDs and requires a different target.
    // ignore: deprecated_member_use
    _tokenSubscription = _messaging.onTokenRefresh.listen((token) {
      if (!_disposed) _tokens.add(token);
    }, onError: (Object _) {});
    _messageSubscription = FirebaseMessaging.onMessage.listen((message) {
      unawaited(_showForeground(message).catchError((Object _) {}));
    }, onError: (Object _) {});
    _openSubscription = FirebaseMessaging.onMessageOpenedApp.listen(
      (message) => _open(PushNotificationTap.fromData(message.data)),
      onError: (Object _) {},
    );
    if (!_initialChecked) {
      final remote = await _messaging.getInitialMessage();
      if (_disposed || version != _version) return;
      if (remote != null) _open(PushNotificationTap.fromData(remote.data));
      final local = await _local.getNotificationAppLaunchDetails();
      if (_disposed || version != _version) return;
      if (local?.didNotificationLaunchApp ?? false) {
        _openLocal(local?.notificationResponse?.payload);
      }
      _initialChecked = true;
    }
    _started = true;
  }

  Future<void> _showForeground(RemoteMessage message) async {
    final tap = PushNotificationTap.fromData(message.data);
    if (_disposed ||
        !_enabled ||
        tap == null ||
        tap.userId != _userId ||
        message.notification == null ||
        !_remember(_shown, tap.key)) {
      return;
    }
    await _local.show(
      id: pushNotificationId(
        message.data['notification_id'] as String? ??
            message.messageId ??
            tap.key,
      ),
      title: message.notification?.title,
      body: message.notification?.body,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          channelId,
          'Project notifications',
          channelDescription: 'Task alerts, deadlines and learning resources.',
          importance: Importance.high,
          priority: Priority.high,
          icon: '@mipmap/ic_launcher',
          tag: tap.notificationId,
        ),
      ),
      payload: tap.toPayload(),
    );
  }

  @override
  Future<bool> requestPermission() async {
    if (!isSupported || _disposed) return false;
    final settings = await _messaging.requestPermission();
    return settings.authorizationStatus == AuthorizationStatus.authorized;
  }

  @override
  Future<bool> hasPermission() async {
    if (!isSupported || _disposed) return false;
    return (await _messaging.getNotificationSettings()).authorizationStatus ==
        AuthorizationStatus.authorized;
  }

  @override
  Future<String?> getToken() async {
    if (!isSupported || _disposed) return null;
    // HTTP v1 registration-token compatibility; see onTokenRefresh above.
    // ignore: deprecated_member_use
    return _messaging.getToken();
  }

  @override
  void setForegroundEnabled(bool enabled) => _enabled = enabled;

  @override
  Future<void> stop({bool invalidateToken = false}) async {
    ++_version;
    _invalidationPending = _invalidationPending || invalidateToken;
    _started = false;
    _enabled = false;
    _userId = null;
    await Future.wait([
      if (_tokenSubscription != null) _tokenSubscription!.cancel(),
      if (_messageSubscription != null) _messageSubscription!.cancel(),
      if (_openSubscription != null) _openSubscription!.cancel(),
    ]);
    _tokenSubscription = null;
    _messageSubscription = null;
    _openSubscription = null;
    _shown.clear();
    if (isSupported && _invalidationPending) {
      try {
        // Unregister the same legacy registration-token API used above.
        // ignore: deprecated_member_use
        await _messaging.deleteToken();
        _invalidationPending = false;
      } catch (_) {
        // Retry invalidation before starting another account's push session.
      }
      if (_localInitialized) await _local.cancelAll();
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await stop();
    await _tokens.close();
    await _taps.close();
  }
}
