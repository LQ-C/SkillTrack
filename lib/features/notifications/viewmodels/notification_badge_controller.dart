import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/notification_change.dart';
import '../repositories/notification_repository.dart';
import '../services/notification_realtime_service.dart';

/// App-scoped badge ViewModel. The existing controller name is kept for callers.
class NotificationBadgeController extends ChangeNotifier {
  NotificationBadgeController(
    this._repository, [
    NotificationChangeSource? realtime,
  ]) {
    _subscription = realtime?.changes.listen(_onChange);
    _syncSubscription = realtime?.syncRequests.listen((_) {
      if (_userId != null && !_disposed) unawaited(refresh());
    });
  }

  final NotificationRepository? _repository;
  StreamSubscription<NotificationChange>? _subscription;
  StreamSubscription<void>? _syncSubscription;
  Timer? _refreshTimer;
  final Map<String, bool> _knownReadStates = {};
  final List<NotificationChange> _duringRefresh = [];
  String? _userId;
  bool _initialized = false;
  bool _refreshing = false;
  bool _disposed = false;
  bool _markingAll = false;
  bool _reconcileFirstEvent = false;
  int _unreadCount = 0;
  int _version = 0;

  int get unreadCount => _unreadCount;

  Future<void> startForUser(String userId) async {
    if (_userId == userId && _initialized) return;
    if (_userId != userId) clear();
    _userId = userId;
    await refresh();
  }

  Future<void> refresh() async {
    if (_disposed) return;
    final userId = _repository?.currentUserId;
    if (userId == null) {
      clear();
      return;
    }
    if (_userId != userId) {
      clear();
      _userId = userId;
    }
    if (_refreshing) {
      _scheduleRefresh();
      return;
    }
    _refreshing = true;
    final version = _version;
    final wasInitialized = _initialized;
    try {
      final count = await _repository!.getUnreadCount();
      if (!_disposed && _userId == userId && version == _version) {
        setCount(count);
        _initialized = true;
        if (!wasInitialized) _reconcileFirstEvent = true;
      }
    } catch (_) {
      // Initial list errors are shown by the notification screen.
    } finally {
      _refreshing = false;
      if (_duringRefresh.isNotEmpty) {
        _duringRefresh.clear();
        _scheduleRefresh();
      }
    }
  }

  void _onChange(NotificationChange change) {
    if (_disposed) return;
    if (change.type == NotificationChangeType.reset) {
      clear();
      return;
    }
    if (change.userId != _userId) return;
    if (!_initialized || _refreshing) {
      _duringRefresh.add(change);
      return;
    }
    final known = _knownReadStates[change.notificationId];
    switch (change.type) {
      case NotificationChangeType.inserted:
      case NotificationChangeType.updated:
        final notification = change.notification;
        if (notification == null || notification.userId != _userId) return;
        final read = notification.isRead;
        if (known != null) {
          if (known != read) setCount(_unreadCount + (read ? -1 : 1));
        } else if (change.type == NotificationChangeType.inserted) {
          if (!read) setCount(_unreadCount + 1);
          if (_reconcileFirstEvent) {
            _reconcileFirstEvent = false;
            _scheduleRefresh();
          }
        } else if (!_markingAll) {
          _scheduleRefresh();
        }
        _knownReadStates[change.notificationId] = read;
      case NotificationChangeType.deleted:
        _knownReadStates.remove(change.notificationId);
        if (known == false) {
          setCount(_unreadCount - 1);
        } else if (known == null) {
          _scheduleRefresh();
        }
      case NotificationChangeType.reset:
        break;
    }
  }

  void _scheduleRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer(const Duration(milliseconds: 180), refresh);
  }

  void markReadLocally(String id) {
    if (_knownReadStates[id] == true) return;
    _knownReadStates[id] = true;
    setCount(_unreadCount - 1);
  }

  void restoreUnread(String id) {
    if (_knownReadStates[id] != true) return;
    _knownReadStates[id] = false;
    setCount(_unreadCount + 1);
  }

  void markAllReadLocally() {
    _markingAll = true;
    for (final id in _knownReadStates.keys.toList()) {
      _knownReadStates[id] = true;
    }
    setCount(0);
  }

  void finishMarkAll({required bool succeeded}) {
    _markingAll = false;
    if (succeeded) _scheduleRefresh();
  }

  void setCount(int value) {
    final next = value < 0 ? 0 : value;
    if (next == _unreadCount) return;
    _unreadCount = next;
    _version++;
    notifyListeners();
  }

  void clear() {
    _refreshTimer?.cancel();
    _userId = null;
    _initialized = false;
    _markingAll = false;
    _reconcileFirstEvent = false;
    _knownReadStates.clear();
    _duringRefresh.clear();
    _version++;
    setCount(0);
  }

  @override
  void dispose() {
    _disposed = true;
    _refreshTimer?.cancel();
    _subscription?.cancel();
    _syncSubscription?.cancel();
    super.dispose();
  }
}
