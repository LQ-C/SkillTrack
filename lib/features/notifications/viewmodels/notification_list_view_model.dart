import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../../kanban/repositories/kanban_repository.dart';
import '../../projects/repositories/project_repository.dart';
import '../models/app_notification.dart';
import '../models/notification_context_type.dart';
import '../models/notification_type.dart';
import '../repositories/notification_repository.dart';
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
  NotificationListViewModel(
    this._repository,
    this._projects,
    this._kanban,
    this._badge,
  );
  final NotificationRepository _repository;
  final ProjectRepository _projects;
  final KanbanRepository _kanban;
  final NotificationBadgeController _badge;
  List<AppNotification> _items = [];
  bool isLoading = true, isRefreshing = false, isMarkingAllRead = false;
  bool _loadStarted = false;
  String? errorMessage, feedbackMessage;
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
    if (initial) {
      isLoading = true;
    } else {
      isRefreshing = true;
    }
    errorMessage = null;
    notifyListeners();
    try {
      _items = await _repository.getNotifications();
      _badge.setCount(await _repository.getUnreadCount());
    } catch (_) {
      errorMessage = 'Unable to load notifications';
    } finally {
      isLoading = false;
      isRefreshing = false;
      notifyListeners();
    }
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
    _items[index] = previous.copyWith(
      isRead: true,
      readAt: DateTime.now().toUtc(),
    );
    _badge.setCount(_badge.unreadCount - 1);
    notifyListeners();
    try {
      await _repository.markAsRead(notificationId);
      return true;
    } catch (_) {
      _items[index] = previous;
      _badge.setCount(_badge.unreadCount + 1);
      feedbackMessage = 'Unable to update notifications. Please try again.';
      notifyListeners();
      return false;
    }
  }

  Future<NotificationOpenResult?> openNotification(AppNotification item) async {
    if (!await markAsRead(item.id)) return null;
    try {
      final projectId = item.projectId;
      if (projectId == null || projectId.isEmpty) return _unavailable();
      final project = await _projects.getProject(projectId);
      if (project == null || project.status == 'archived') {
        return _unavailable();
      }
      final boardId =
          item.boardId ?? await _projects.getProjectBoard(projectId);
      if (boardId == null || boardId.isEmpty) return _unavailable();
      if (item.contextType != NotificationContextType.project) {
        final taskId = item.taskId;
        if (taskId == null || taskId.isEmpty) return _unavailable();
        final tasks = await _kanban.getTasks(boardId);
        if (!tasks.any((task) => task.id == taskId)) return _unavailable();
      }
      return NotificationOpenResult(
        projectId: projectId,
        boardId: boardId,
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
    feedbackMessage = 'This item is no longer available.';
    notifyListeners();
    return null;
  }

  Future<void> markAllAsRead() async {
    if (isMarkingAllRead || unreadCount == 0) return;
    isMarkingAllRead = true;
    final previous = List<AppNotification>.of(_items);
    final count = unreadCount;
    final now = DateTime.now().toUtc();
    _items = _items
        .map(
          (item) =>
              item.isRead ? item : item.copyWith(isRead: true, readAt: now),
        )
        .toList();
    _badge.setCount(0);
    notifyListeners();
    try {
      await _repository.markAllAsRead();
      feedbackMessage = 'All notifications marked as read';
    } catch (_) {
      _items = previous;
      _badge.setCount(count);
      feedbackMessage = 'Unable to update notifications. Please try again.';
    } finally {
      isMarkingAllRead = false;
      notifyListeners();
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
}
