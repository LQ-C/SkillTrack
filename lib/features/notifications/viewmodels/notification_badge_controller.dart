import 'package:flutter/foundation.dart';

import '../repositories/notification_repository.dart';

class NotificationBadgeController extends ChangeNotifier {
  NotificationBadgeController(this._repository);
  final NotificationRepository? _repository;
  int _unreadCount = 0;
  int _version = 0;
  int get unreadCount => _unreadCount;

  Future<void> refresh() async {
    final version = _version;
    if (_repository?.currentUserId == null) {
      setCount(0);
      return;
    }
    try {
      final count = await _repository!.getUnreadCount();
      if (version == _version) setCount(count);
    } catch (_) {
      // The notification screen exposes the actionable load error.
    }
  }

  void setCount(int value) {
    final next = value < 0 ? 0 : value;
    if (next == _unreadCount) return;
    _unreadCount = next;
    _version++;
    notifyListeners();
  }
}
