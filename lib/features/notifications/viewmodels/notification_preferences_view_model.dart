import 'package:flutter/foundation.dart';

import '../models/notification_preferences.dart';
import '../repositories/notification_repository.dart';

class NotificationPreferencesViewModel extends ChangeNotifier {
  NotificationPreferencesViewModel(this._repository)
    : preferences = NotificationPreferences.defaults(
        _repository.currentUserId ?? '',
      );
  final NotificationRepository _repository;
  bool _disposed = false;
  NotificationPreferences preferences;
  bool isLoading = true, isSaving = false;
  bool hasLoaded = false;
  String? errorMessage;

  Future<void> initialize() async {
    if (_disposed) return;
    isLoading = true;
    errorMessage = null;
    notifyListeners();
    try {
      final loaded = await _repository.getPreferences();
      if (_disposed) return;
      preferences = loaded;
      hasLoaded = true;
    } catch (_) {
      if (_disposed) return;
      errorMessage = 'Unable to load notification preferences.';
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  Future<void> retry() => initialize();

  Future<void> _save(NotificationPreferences next) async {
    if (_disposed || isSaving) return;
    final previous = preferences;
    preferences = next;
    isSaving = true;
    errorMessage = null;
    notifyListeners();
    try {
      final saved = await _repository.updatePreferences(next);
      if (_disposed) return;
      preferences = saved;
    } catch (_) {
      if (_disposed) return;
      preferences = previous;
      errorMessage = 'Unable to save preferences. Please try again.';
    } finally {
      isSaving = false;
      notifyListeners();
    }
  }

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
