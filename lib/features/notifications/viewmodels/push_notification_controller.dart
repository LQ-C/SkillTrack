import 'dart:async';

import '../../../core/errors/app_exception.dart';
import '../repositories/notification_repository.dart';
import '../repositories/push_device_repository.dart';
import '../services/push_notification_service.dart';

abstract interface class PushPreferenceActions {
  Future<void> setEnabled(bool enabled, {bool requestPermission = false});
}

/// One application-scoped coordinator. No BuildContext or navigation state.
class PushNotificationController implements PushPreferenceActions {
  PushNotificationController(this._preferences, this._devices, this._service);
  final NotificationRepository _preferences;
  final PushDeviceRepository _devices;
  final PushNotificationService _service;
  final _taps = StreamController<PushNotificationTap>.broadcast();
  final _opened = <String>{};
  StreamSubscription<String>? _tokenSubscription;
  StreamSubscription<PushNotificationTap>? _tapSubscription;
  Future<void> _queue = Future.value();
  String? _userId, _desiredUser, _registeredToken;
  DateTime? _registeredAt;
  bool _enabled = false, _disposed = false, _preferencesLoaded = false;
  int _version = 0;
  bool _serviceReady = false;
  String? errorMessage;

  Stream<PushNotificationTap> get taps => _taps.stream;
  bool get isEnabled => _enabled;
  bool _isCurrent(String userId, int version) =>
      !_disposed &&
      version == _version &&
      _desiredUser == userId &&
      _preferences.currentUserId == userId &&
      _devices.currentUserId == userId;

  Future<void> _serial(Future<void> Function() operation) {
    final next = _queue.then((_) async {
      if (!_disposed) await operation();
    });
    _queue = next.catchError((Object _) {});
    return next;
  }

  Future<void> syncSession({bool resumed = false}) {
    final user = _preferences.currentUserId;
    if (user != _desiredUser) {
      _desiredUser = user;
      ++_version;
      _service.setForegroundEnabled(false);
    }
    final version = _version;
    return _serial(() async {
      if (_disposed || version != _version) return;
      try {
        if (_userId != user || user == null) {
          await _stop(invalidateToken: _userId != null || user == null);
          if (_disposed || version != _version) return;
          _userId = user;
        }
        if (user == null || !_service.isSupported) return;
        final first = _tokenSubscription == null;
        if (first) {
          _tapSubscription = _service.taps.listen((tap) {
            if (!_isCurrent(user, version) ||
                tap.userId != user ||
                !_opened.add(tap.key)) {
              return;
            }
            if (_opened.length > 256) _opened.remove(_opened.first);
            _taps.add(tap);
          });
          _tokenSubscription = _service.tokenChanges.listen((token) {
            unawaited(
              _serial(() async {
                if (_enabled && _isCurrent(user, version)) {
                  try {
                    if (await _service.hasPermission()) {
                      await _register(user, version, token);
                    }
                  } catch (_) {
                    errorMessage =
                        'Unable to refresh this device’s push registration.';
                  }
                }
              }),
            );
          });
        }
        await _service.start(user);
        _serviceReady = true;
        if (!_isCurrent(user, version)) return;
        if (!_preferencesLoaded || resumed) {
          final preferences = await _preferences.getPreferences();
          if (!_isCurrent(user, version)) return;
          _enabled = preferences.pushEnabled;
          _preferencesLoaded = true;
        }
        await _reconcile(user, version);
        errorMessage = null;
      } catch (_) {
        _service.setForegroundEnabled(false);
        _serviceReady = false;
        errorMessage = 'Unable to synchronize push notifications.';
      }
    });
  }

  Future<void> _register(String user, int version, String token) async {
    if (!_isCurrent(user, version) || token.isEmpty) return;
    if (_registeredToken == token &&
        _registeredAt != null &&
        DateTime.now().difference(_registeredAt!) < const Duration(hours: 24)) {
      return;
    }
    await _devices.register(token);
    if (!_isCurrent(user, version)) return;
    final previous = _registeredToken;
    _registeredToken = token;
    _registeredAt = DateTime.now();
    if (previous != null && previous != token) {
      await _devices.unregister(previous);
    }
  }

  Future<void> _reconcile(String user, int version) async {
    final permitted = _enabled && await _service.hasPermission();
    if (!_isCurrent(user, version)) return;
    _service.setForegroundEnabled(permitted);
    if (permitted) {
      final token = await _service.getToken();
      if (token != null) await _register(user, version, token);
    } else if (_registeredToken != null) {
      await _devices.unregister(_registeredToken!);
      _registeredToken = null;
      _registeredAt = null;
    }
  }

  @override
  Future<void> setEnabled(
    bool enabled, {
    bool requestPermission = false,
  }) async {
    final user = _preferences.currentUserId;
    if (user == null) {
      throw const AppException('Sign in to manage push notifications.');
    }
    if (!_service.isSupported) {
      throw const AppException('Push notifications are available on Android.');
    }
    await syncSession();
    await _serial(() async {
      final version = _version;
      if (!_serviceReady) {
        throw const AppException(
          'Unable to initialize push notifications. Please try again.',
        );
      }
      if (!_isCurrent(user, version)) {
        throw const AppException('Sign in again to update push notifications.');
      }
      if (enabled) {
        final authorized = requestPermission
            ? await _service.requestPermission()
            : await _service.hasPermission();
        if (!_isCurrent(user, version)) return;
        if (!authorized) {
          throw const AppException(
            'Notification permission was denied. Allow notifications in Android settings to enable push.',
          );
        }
        final token = await _service.getToken();
        if (!_isCurrent(user, version)) return;
        if (token == null || token.isEmpty) {
          throw const AppException(
            'Unable to register this device. Please try again.',
          );
        }
        await _register(user, version, token);
      } else {
        _service.setForegroundEnabled(false);
        final token = _registeredToken;
        _enabled = false;
        if (token != null && _isCurrent(user, version)) {
          await _devices.unregister(token);
        }
        _registeredToken = null;
        _registeredAt = null;
      }
      if (_isCurrent(user, version)) {
        _enabled = enabled;
        _service.setForegroundEnabled(enabled);
      }
    });
  }

  Future<void> _stop({required bool invalidateToken}) async {
    _enabled = false;
    _serviceReady = false;
    _preferencesLoaded = false;
    _service.setForegroundEnabled(false);
    await _tokenSubscription?.cancel();
    await _tapSubscription?.cancel();
    _tokenSubscription = null;
    _tapSubscription = null;
    try {
      if (_registeredToken != null && _devices.currentUserId == _userId) {
        await _devices.unregister(_registeredToken!);
      }
    } catch (_) {
      // Firebase invalidation also prevents delivery to the previous account.
    }
    await _service.stop(invalidateToken: invalidateToken);
    _registeredToken = null;
    _registeredAt = null;
    _userId = null;
    _opened.clear();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    ++_version;
    await _stop(invalidateToken: false);
    await _service.dispose();
    await _taps.close();
  }
}
