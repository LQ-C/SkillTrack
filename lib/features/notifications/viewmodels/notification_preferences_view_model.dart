import 'package:flutter/foundation.dart';

import '../../../core/errors/app_exception.dart';
import '../models/notification_preferences.dart';
import 'push_notification_controller.dart';
import '../repositories/notification_repository.dart';

class NotificationPreferencesViewModel extends ChangeNotifier {
  NotificationPreferencesViewModel(
    this._repository, {
    PushPreferenceActions? push,
  }) : _push = push,
       preferences = NotificationPreferences.defaults(
         _repository.currentUserId ?? '',
       );
  final NotificationRepository _repository;
  final PushPreferenceActions? _push;
  bool _disposed = false;
  NotificationPreferences preferences;
  bool isLoading = true, isSaving = false;
  bool hasLoaded = false;
  bool _isInitializing = false;
  String? errorMessage;

  Future<void> initialize() async {
    if (_disposed || _isInitializing || isSaving) return;
    _isInitializing = true;
    isLoading = true;
    errorMessage = null;
    notifyListeners();
    try {
      final loaded = await _repository.getPreferences();
      if (_disposed) return;
      preferences = loaded;
      hasLoaded = true;
    } catch (_) {
      if (!_disposed) errorMessage = 'Unable to load notification preferences.';
    } finally {
      _isInitializing = false;
      isLoading = false;
      notifyListeners();
    }
  }

  Future<void> retry() => initialize();

  Future<void> _save(
    NotificationPreferences next, {
    bool pushChanged = false,
  }) async {
    if (_disposed || isSaving || _isInitializing) return;
    final previous = preferences;
    preferences = next;
    isSaving = true;
    errorMessage = null;
    notifyListeners();
    var committed = false;
    try {
      if (pushChanged && next.pushEnabled) {
        if (_push == null) {
          throw const AppException(
            'Push notifications are unavailable on this device.',
          );
        }
        await _push.setEnabled(true, requestPermission: true);
      }
      final saved = await _repository.updatePreferences(next);
      committed = true;
      if (pushChanged) await _push?.setEnabled(next.pushEnabled);
      if (_disposed) return;
      preferences = saved;
    } catch (error) {
      if (_disposed) return;
      if (!committed) {
        preferences = previous;
        if (pushChanged && next.pushEnabled) {
          try {
            await _push?.setEnabled(previous.pushEnabled);
          } catch (_) {}
        }
      }
      errorMessage = committed
          ? next.pushEnabled
                ? 'Push preference saved. Check Android notification permission and try again.'
                : 'Push is disabled. Device cleanup will be retried when the app resumes.'
          : AppException.messageFor(
              error,
              fallback: 'Unable to save preferences. Please try again.',
            );
    } finally {
      isSaving = false;
      notifyListeners();
    }
  }

  Future<void> setPushEnabled(bool value) =>
      _save(preferences.copyWith(pushEnabled: value), pushChanged: true);

  Future<void> setStalledTaskEnabled(bool value) =>
      _save(preferences.copyWith(stalledTaskEnabled: value));
  Future<void> setDeadlineReminderEnabled(bool value) =>
      _save(preferences.copyWith(deadlineReminderEnabled: value));
  Future<void> setRecommendationEnabled(bool value) =>
      _save(preferences.copyWith(recommendationEnabled: value));

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
