import 'package:flutter/foundation.dart';

import '../models/notification_preferences.dart';
import '../repositories/notification_repository.dart';

class NotificationPreferencesViewModel extends ChangeNotifier {
  NotificationPreferencesViewModel(this._repository)
    : preferences = NotificationPreferences.defaults(
        _repository.currentUserId ?? '',
      );
  final NotificationRepository _repository;
  NotificationPreferences preferences;
  bool isLoading = true, isSaving = false;
  bool hasLoaded = false;
  String? errorMessage;

  Future<void> initialize() async {
    isLoading = true;
    errorMessage = null;
    notifyListeners();
    try {
      preferences = await _repository.getPreferences();
      hasLoaded = true;
    } catch (_) {
      errorMessage = 'Unable to load notification preferences.';
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  Future<void> retry() => initialize();

  Future<void> _save(NotificationPreferences next) async {
    if (isSaving) return;
    final previous = preferences;
    preferences = next;
    isSaving = true;
    errorMessage = null;
    notifyListeners();
    try {
      preferences = await _repository.updatePreferences(next);
    } catch (_) {
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
}
