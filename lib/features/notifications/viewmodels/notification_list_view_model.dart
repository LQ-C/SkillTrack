import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../../kanban/repositories/kanban_repository.dart';
import '../../projects/repositories/project_repository.dart';
import '../models/app_notification.dart';
import '../models/notification_change.dart';
import '../models/notification_context_type.dart';
import '../models/notification_type.dart';
import '../repositories/notification_repository.dart';
import '../services/notification_realtime_service.dart';
import 'notification_badge_controller.dart';

enum NotificationListFilter { all, unread, stalled, deadlines, resources }

class NotificationOpenResult {
  const NotificationOpenResult({
    required this.projectId,
    required this.boardId,
    required this.projectName,
    this.taskId,
    this.openRecommendations = false,
    this.showStalledWarning = false,
    this.resourceTitles = const [],
    this.resourceCount = 0,
  });
  final String projectId, boardId, projectName;
  final String? taskId;
  final bool openRecommendations, showStalledWarning;
  final List<String> resourceTitles;
  final int resourceCount;
}

class NotificationListViewModel extends ChangeNotifier {
  static const _pageSize = 50;

  NotificationListViewModel(
    this._repository,
    this._projects,
    this._kanban,
    this._badge, [
    this._realtime,
  ]) {
    _changes = _realtime?.changes.listen(_onChange);
    _syncRequests = _realtime?.syncRequests.listen((_) {
      if (_loadStarted && !isLoading) unawaited(refresh());
    });
    _badge.addListener(_onBadgeChanged);
  }
  final NotificationRepository _repository;
  final ProjectRepository _projects;
  final KanbanRepository _kanban;
  final NotificationBadgeController _badge;
  final NotificationChangeSource? _realtime;
  StreamSubscription<NotificationChange>? _changes;
  StreamSubscription<void>? _syncRequests;
  final List<NotificationChange> _bufferedChanges = [];
  List<AppNotification> _items = [];
  bool isLoading = true, isRefreshing = false, isMarkingAllRead = false;
  bool isLoadingMore = false, hasMore = false;
  bool _loadStarted = false;
  bool _disposed = false;
  int _loadVersion = 0;
  String? errorMessage, feedbackMessage, loadMoreError;
  NotificationListFilter selectedFilter = NotificationListFilter.all;

  List<AppNotification> get allNotifications => UnmodifiableListView(_items);
  int get unreadCount => _badge.unreadCount;
  bool get isEmpty => _items.isEmpty;
  bool get isFilteredEmpty => !isEmpty && visibleNotifications.isEmpty;
  List<AppNotification> get visibleNotifications => UnmodifiableListView(
    _items.where(
      (item) => switch (selectedFilter) {
        NotificationListFilter.all => true,
        NotificationListFilter.unread => item.isUnread,
        NotificationListFilter.stalled =>
          item.type == NotificationType.stalledTask,
        NotificationListFilter.deadlines =>
          item.type == NotificationType.deadlineReminder,
        NotificationListFilter.resources =>
          item.type == NotificationType.learningResourceRecommendation,
      },
    ),
  );

  Future<void> initialize() => _load(initial: true);
  Future<void> refresh() => _load(initial: false);
  Future<void> retry() => _load(initial: true);

  Future<void> _load({required bool initial}) async {
    if (_loadStarted && (isLoading || isRefreshing)) return;
    _loadStarted = true;
    final userId = _repository.currentUserId;
    final version = ++_loadVersion;
    if (initial) {
      isLoading = true;
    } else {
      isRefreshing = true;
    }
    errorMessage = null;
    notifyListeners();
    try {
      if (userId != null) await _realtime?.startForUser(userId);
      final fetched = await _repository.getNotifications(limit: _pageSize);
      if (_disposed ||
          version != _loadVersion ||
          _repository.currentUserId != userId) {
        return;
      }
      _items = _sortedUnique(fetched);
      hasMore = fetched.length == _pageSize;
      loadMoreError = null;
      for (final change in _bufferedChanges) {
        _apply(change);
      }
      _bufferedChanges.clear();
      if (_realtime == null) {
        _badge.setCount(await _repository.getUnreadCount());
      }
    } catch (_) {
      if (!_disposed && version == _loadVersion) {
        errorMessage = 'Unable to load notifications';
      }
    } finally {
      if (!_disposed && version == _loadVersion) {
        isLoading = false;
        isRefreshing = false;
        notifyListeners();
      }
    }
  }

  Future<void> loadMore() async {
    if (_disposed ||
        !hasMore ||
        isLoadingMore ||
        isLoading ||
        isRefreshing ||
        _items.isEmpty) {
      return;
    }
    final userId = _repository.currentUserId;
    final version = _loadVersion;
    isLoadingMore = true;
    loadMoreError = null;
    notifyListeners();
    try {
      final page = await _repository.getNotifications(
        limit: _pageSize,
        before: _items.last.createdAt,
      );
      if (_disposed ||
          version != _loadVersion ||
          _repository.currentUserId != userId) {
        return;
      }
      _items = _sortedUnique([...page, ..._items]);
      hasMore = page.length == _pageSize;
    } catch (_) {
      if (!_disposed && version == _loadVersion) {
        loadMoreError = 'Unable to load older notifications.';
      }
    } finally {
      if (!_disposed && version == _loadVersion) {
        isLoadingMore = false;
        notifyListeners();
      }
    }
  }

  void _onBadgeChanged() {
    if (!_disposed) notifyListeners();
  }

  void _onChange(NotificationChange change) {
    if (_disposed) return;
    if (change.type == NotificationChangeType.reset) {
      ++_loadVersion;
      _bufferedChanges.clear();
      _items = [];
      _loadStarted = false;
      isLoading = false;
      isRefreshing = false;
      isLoadingMore = false;
      isMarkingAllRead = false;
      hasMore = false;
      loadMoreError = null;
      errorMessage = null;
      notifyListeners();
      return;
    }
    if (change.userId != _repository.currentUserId ||
        (change.notification != null &&
            change.notification!.userId != change.userId)) {
      return;
    }
    if (!_loadStarted || isLoading || isRefreshing) {
      _bufferedChanges.add(change);
      return;
    }
    if (_apply(change)) notifyListeners();
  }

  bool _apply(NotificationChange change) {
    final index = _items.indexWhere((item) => item.id == change.notificationId);
    switch (change.type) {
      case NotificationChangeType.inserted:
        final notification = change.notification;
        if (notification == null) return false;
        if (index >= 0 && _items[index] == notification) return false;
        if (index >= 0) _items.removeAt(index);
        _items.add(notification);
        _items = _sortedUnique(_items);
        return true;
      case NotificationChangeType.updated:
        final notification = change.notification;
        if (index < 0 ||
            notification == null ||
            _items[index] == notification) {
          return false;
        }
        _items[index] = notification;
        _items = _sortedUnique(_items);
        return true;
      case NotificationChangeType.deleted:
        if (index < 0) return false;
        _items.removeAt(index);
        return true;
      case NotificationChangeType.reset:
        return false;
    }
  }

  List<AppNotification> _sortedUnique(Iterable<AppNotification> items) {
    final byId = <String, AppNotification>{
      for (final item in items) item.id: item,
    };
    return byId.values.toList()..sort((a, b) {
      final byDate = b.createdAt.compareTo(a.createdAt);
      return byDate != 0 ? byDate : b.id.compareTo(a.id);
    });
  }

  void setFilter(NotificationListFilter filter) {
    if (filter == selectedFilter) return;
    selectedFilter = filter;
    notifyListeners();
  }

  Future<bool> markAsRead(String notificationId) async {
    final index = _items.indexWhere((item) => item.id == notificationId);
    if (index < 0 || _items[index].isRead) return true;
    final previous = _items[index];
    final version = _loadVersion;
    _items[index] = previous.copyWith(
      isRead: true,
      readAt: DateTime.now().toUtc(),
    );
    _badge.markReadLocally(notificationId);
    notifyListeners();
    try {
      await _repository.markAsRead(notificationId);
      return !_disposed &&
          version == _loadVersion &&
          _repository.currentUserId == previous.userId;
    } catch (_) {
      if (_disposed ||
          version != _loadVersion ||
          _repository.currentUserId != previous.userId) {
        return false;
      }
      final current = _items.indexWhere((item) => item.id == notificationId);
      if (current >= 0) _items[current] = previous;
      _badge.restoreUnread(notificationId);
      feedbackMessage = 'Unable to update notifications. Please try again.';
      notifyListeners();
      return false;
    }
  }

  Future<NotificationOpenResult?> openNotification(AppNotification item) async {
    if (_disposed || _repository.currentUserId != item.userId) return null;
    if (!await markAsRead(item.id)) return null;
    try {
      final projectId = item.projectId;
      if (projectId == null || projectId.isEmpty) return _unavailable();
      final project = await _projects.getProject(projectId);
      if (project == null || project.status == 'archived') {
        return _unavailable();
      }
      String? boardId;
      if (item.contextType != NotificationContextType.project) {
        boardId = item.boardId ?? await _projects.getProjectBoard(projectId);
        if (boardId == null || boardId.isEmpty) return _unavailable();
        final taskId = item.taskId;
        if (taskId == null || taskId.isEmpty) return _unavailable();
        final tasks = await _kanban.getTasks(boardId);
        if (!tasks.any((task) => task.id == taskId)) return _unavailable();
      }
      if (_disposed || _repository.currentUserId != item.userId) return null;
      return NotificationOpenResult(
        projectId: projectId,
        boardId: boardId ?? '',
        projectName: project.name,
        taskId: item.contextType == NotificationContextType.project
            ? null
            : item.taskId,
        openRecommendations:
            item.type == NotificationType.learningResourceRecommendation,
        showStalledWarning: item.type == NotificationType.stalledTask,
        resourceTitles:
            (item.actionData['resource_titles'] as List? ?? const [])
                .whereType<String>()
                .toList(),
        resourceCount:
            (item.actionData['resource_count'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return _unavailable();
    }
  }

  NotificationOpenResult? _unavailable() {
    if (_disposed) return null;
    feedbackMessage = 'This item is no longer available.';
    notifyListeners();
    return null;
  }

  Future<void> markAllAsRead() async {
    if (isMarkingAllRead || unreadCount == 0) return;
    final version = _loadVersion;
    final userId = _repository.currentUserId;
    isMarkingAllRead = true;
    final previous = List<AppNotification>.of(_items);
    final now = DateTime.now().toUtc();
    _items = _items
        .map(
          (item) =>
              item.isRead ? item : item.copyWith(isRead: true, readAt: now),
        )
        .toList();
    _badge.markAllReadLocally();
    notifyListeners();
    try {
      await _repository.markAllAsRead();
      if (_disposed ||
          version != _loadVersion ||
          _repository.currentUserId != userId) {
        return;
      }
      _badge.finishMarkAll(succeeded: true);
      feedbackMessage = 'All notifications marked as read';
    } catch (_) {
      if (_disposed ||
          version != _loadVersion ||
          _repository.currentUserId != userId) {
        return;
      }
      final originals = {for (final item in previous) item.id: item};
      _items = [for (final item in _items) originals[item.id] ?? item];
      _badge.finishMarkAll(succeeded: false);
      await _badge.refresh();
      feedbackMessage = 'Unable to update notifications. Please try again.';
    } finally {
      if (!_disposed && version == _loadVersion) {
        isMarkingAllRead = false;
        notifyListeners();
      }
    }
  }

  void clearError() {
    errorMessage = null;
    notifyListeners();
  }

  void clearFeedbackMessage() {
    feedbackMessage = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _changes?.cancel();
    _syncRequests?.cancel();
    _badge.removeListener(_onBadgeChanged);
    super.dispose();
  }
}
