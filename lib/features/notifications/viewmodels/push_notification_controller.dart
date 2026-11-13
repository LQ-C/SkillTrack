import '../../../core/constants/app_constants.dart';
import 'dart:async';
import 'package:flutter/foundation.dart';
import '../services/notification_installation_service.dart';

import '../../../core/errors/app_exception.dart';
import '../repositories/notification_repository.dart';
import '../repositories/push_device_repository.dart';
import '../services/push_notification_service.dart';

abstract interface class PushPreferenceActions {
  Future<void> setEnabled(bool enabled, {bool requestPermission = false});
}

/// One application-scoped coordinator. No BuildContext or navigation state.
class PushPermissionOffer {
  const PushPermissionOffer(this.user, this.version, this.settings);
  final String user;
  final int version;
  final bool settings;
}

abstract interface class PushPermissionActions {
  Future<void> rememberPushChoice(bool enabled);
  Future<void> openNotificationSettings();
}

class PushNotificationController extends ChangeNotifier
    implements PushPreferenceActions, PushPermissionActions {
  PushNotificationController(
    this._preferences,
    this._devices,
    this._service, {
    NotificationInstallationService? installation,
  }) : _installation = installation;
  final NotificationInstallationService? _installation;
  PushPermissionOffer? offer;
  PushPermissionOffer? _settingsConsent;
  bool _checkingOnboarding = false, _consenting = false;
  bool get onboardingAvailable =>
      _installation?.supported == true && _service.isSupported;
  bool isOfferCurrent(PushPermissionOffer value) =>
      _isCurrent(value.user, value.version);
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<PushPermissionOffer?> prepareOnboarding() async {
    if (!onboardingAvailable ||
        _disposed ||
        _checkingOnboarding ||
        _consenting) {
      return null;
    }
    _checkingOnboarding = true;
    try {
      await syncSession();
      final user = _preferences.currentUserId, version = _version;
      if (user == null || !_serviceReady || !_isCurrent(user, version)) {
        return null;
      }
      final state = await _installation!.read(user);
      if (!_isCurrent(user, version) ||
          state.handled ||
          state.optedOut ||
          (state.granted && _enabled)) {
        return null;
      }
      // Persist before presentation: rebuilds, another login and process death do not nag.
      await _installation.markHandled();
      if (!_isCurrent(user, version)) return null;
      offer = PushPermissionOffer(
        user,
        version,
        !state.granted && !state.canRequest,
      );
      return offer;
    } catch (_) {
      return null;
    } finally {
      _checkingOnboarding = false;
    }
  }

  void dismissOffer(PushPermissionOffer value) {
    if (identical(offer, value)) {
      offer = null;
      _changed();
    }
  }

  Future<void> acceptOffer(PushPermissionOffer value) async {
    if (_consenting || !identical(offer, value) || !isOfferCurrent(value)) {
      return;
    }
    offer = null;
    _changed();
    if (value.settings) {
      _settingsConsent = value;
      try {
        await _installation!.openSettings();
      } catch (_) {
        _settingsConsent = null;
        errorMessage = 'Unable to open Android notification settings.';
      }
    } else {
      await _enableWithConsent(value);
    }
  }

  Future<void> _enableWithConsent(PushPermissionOffer value) async {
    if (_consenting || !isOfferCurrent(value)) return;
    _consenting = true;
    try {
      await setEnabled(true, requestPermission: true);
      if (!isOfferCurrent(value)) return;
      // Reload category switches instead of overwriting them with stale defaults.
      final previous = await _preferences.getPreferences();
      if (!isOfferCurrent(value)) return;
      await _preferences.updatePreferences(
        previous.copyWith(pushEnabled: true),
      );
      if (!isOfferCurrent(value)) return;
      await rememberPushChoice(true);
      errorMessage = null;
    } catch (error) {
      if (isOfferCurrent(value)) {
        try {
          await setEnabled(false);
        } catch (_) {}
        errorMessage = AppException.messageFor(
          error,
          fallback:
              'Unable to enable push. You can try again in Notification Preferences.',
        );
      }
    } finally {
      _consenting = false;
      _changed();
    }
  }

  Future<void> resumePermissionOnboarding() async {
    final pending = _settingsConsent;
    if (pending == null || !isOfferCurrent(pending)) {
      _settingsConsent = null;
      return;
    }
    _settingsConsent = null;
    try {
      if ((await _installation!.read(pending.user)).granted &&
          isOfferCurrent(pending)) {
        await _enableWithConsent(pending);
      }
    } catch (_) {
      /* Login and in-app notifications remain available. */
    }
  }

  Future<String?> permissionGuidance() async {
    final user = _preferences.currentUserId;
    if (!onboardingAvailable || user == null) return null;
    try {
      final state = await _installation!.read(user);
      if (_preferences.currentUserId != user || _disposed) return null;
      return state.granted
          ? 'Android notification permission is allowed. Your account push preference is controlled by the switch below.'
          : state.canRequest
          ? 'Android notification permission has not been allowed. Enable push to request it.'
          : PushPermissionMessages.settingsRequired;
    } catch (_) {
      return 'Unable to check Android notification permission. You can still use in-app notifications.';
    }
  }

  @override
  Future<void> rememberPushChoice(bool enabled) async {
    final user = _preferences.currentUserId;
    if (user != null && onboardingAvailable) {
      await _installation!.rememberChoice(user, enabled);
    }
  }

  @override
  Future<void> openNotificationSettings() async {
    if (!onboardingAvailable) return;
    await _installation!.openSettings();
  }

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
  final _pendingRetirements = <String>{};
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
      offer = null;
      _settingsConsent = null;
      _changed();
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
        if (!_preferencesLoaded || (resumed && !_consenting)) {
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
    await _retirePreviousTokens(user, version);
    if (!_isCurrent(user, version)) return;
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
      _pendingRetirements.add(previous);
      await _retirePreviousTokens(user, version);
    }
  }

  Future<void> _retirePreviousTokens(String user, int version) async {
    for (final token in _pendingRetirements.toList()) {
      if (!_isCurrent(user, version)) return;
      await _devices.unregister(token);
      if (!_isCurrent(user, version)) return;
      _pendingRetirements.remove(token);
    }
  }

  Future<void> _reconcile(String user, int version) async {
    await _retirePreviousTokens(user, version);
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
        var authorized = requestPermission && !onboardingAvailable
            ? false
            : await _service.hasPermission();
        if (!authorized && requestPermission) {
          if (onboardingAvailable) {
            final state = await _installation!.read(user);
            if (!_isCurrent(user, version)) return;
            if (!state.canRequest) {
              throw const AppException(PushPermissionMessages.settingsRequired);
            }
            await _installation.markRequested();
            if (!_isCurrent(user, version)) return;
          }
          authorized = await _service.requestPermission();
        }
        if (!_isCurrent(user, version)) return;
        if (!authorized) {
          throw const AppException(PushPermissionMessages.denied);
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
    if (_devices.currentUserId == _userId) {
      for (final token in {..._pendingRetirements, ?_registeredToken}) {
        if (_devices.currentUserId != _userId) break;
        try {
          await _devices.unregister(token);
        } catch (_) {
          // Token invalidation remains the fallback when server cleanup fails.
        }
      }
    }
    await _service.stop(invalidateToken: invalidateToken);
    _registeredToken = null;
    _registeredAt = null;
    _pendingRetirements.clear();
    _userId = null;
    _opened.clear();
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    ++_version;
    await _stop(invalidateToken: false);
    await _service.dispose();
    await _taps.close();
    super.dispose();
  }
}
