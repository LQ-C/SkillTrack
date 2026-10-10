import '../models/app_notification.dart';
import '../models/notification_context_type.dart';
import '../models/notification_type.dart';
import '../repositories/notification_repository.dart';

/// Called by trusted monitoring/recommendation events; never schedules deadlines.
class NotificationEventCoordinator {
  NotificationEventCoordinator(
    this.repository, {
    DateTime Function()? clock,
    this.onNotificationCreated,
  }) : _clock = clock ?? DateTime.now;
  final NotificationRepository repository;
  final DateTime Function() _clock;
  final Future<void> Function()? onNotificationCreated;

  Future<void> _emit({
    required String userId,
    required NotificationType type,
    required NotificationContextType context,
    required String projectId,
    String? boardId,
    String? taskId,
    required String title,
    required String message,
    required String uniqueKey,
    Map<String, dynamic> actionData = const {},
  }) async {
    if (repository.currentUserId != userId ||
        await repository.notificationExists(uniqueKey)) {
      return;
    }
    try {
      await repository.createNotification(
        AppNotification(
          id: '',
          userId: userId,
          type: type,
          contextType: context,
          projectId: projectId,
          boardId: boardId,
          taskId: taskId,
          title: title,
          message: message,
          uniqueKey: uniqueKey,
          actionData: actionData,
          createdAt: _clock().toUtc(),
        ),
      );
      await onNotificationCreated?.call();
    } catch (_) {
      // A concurrent event can win the unique-key insert; other failures propagate.
      if (!await repository.notificationExists(uniqueKey)) rethrow;
    }
  }

  Future<void> notifyTaskStalled({
    required String userId,
    required String projectId,
    required String boardId,
    required String taskId,
    required String taskTitle,
    required DateTime stalledAt,
    bool isInProgress = true,
    bool isArchived = false,
  }) async {
    if (!isInProgress ||
        isArchived ||
        !(await repository.getPreferences()).stalledTaskEnabled) {
      return;
    }
    await _emit(
      userId: userId,
      type: NotificationType.stalledTask,
      context: NotificationContextType.task,
      projectId: projectId,
      boardId: boardId,
      taskId: taskId,
      title: 'Task may be stalled',
      message: '“$taskTitle” has exceeded its inactivity threshold.',
      uniqueKey: 'stalled:$taskId:${stalledAt.toUtc().toIso8601String()}',
    );
  }

  Future<void> notifyTaskDeadline({
    required String userId,
    required String projectId,
    required String boardId,
    required String taskId,
    required String taskTitle,
    required DateTime deadline,
    required String reminderWindow,
    bool isCompleted = false,
    bool isArchived = false,
  }) async {
    if (isCompleted ||
        isArchived ||
        !(await repository.getPreferences()).deadlineReminderEnabled) {
      return;
    }
    await _emit(
      userId: userId,
      type: NotificationType.deadlineReminder,
      context: NotificationContextType.task,
      projectId: projectId,
      boardId: boardId,
      taskId: taskId,
      title: 'Task deadline approaching',
      message: '“$taskTitle” is due $reminderWindow.',
      uniqueKey:
          'task-deadline:$taskId:${deadline.toUtc().toIso8601String()}:$reminderWindow',
    );
  }

  Future<void> notifyProjectDeadline({
    required String userId,
    required String projectId,
    required String projectName,
    required DateTime deadline,
    required String reminderWindow,
    String? boardId,
    bool isActive = true,
  }) async {
    if (!isActive ||
        !(await repository.getPreferences()).deadlineReminderEnabled) {
      return;
    }
    await _emit(
      userId: userId,
      type: NotificationType.deadlineReminder,
      context: NotificationContextType.project,
      projectId: projectId,
      boardId: boardId,
      title: 'Project deadline approaching',
      message: '“$projectName” is due $reminderWindow.',
      uniqueKey:
          'project-deadline:$projectId:${deadline.toUtc().toIso8601String()}:$reminderWindow',
    );
  }

  Future<void> notifyLearningResourcesAvailable({
    required String userId,
    required String projectId,
    required String boardId,
    required String taskId,
    required String taskTitle,
    required int resourceCount,
    required String recommendationBatchId,
    List<String> resourceTitles = const [],
    bool isStalled = true,
  }) async {
    if (!isStalled ||
        resourceCount < 1 ||
        !(await repository.getPreferences()).recommendationEnabled) {
      return;
    }
    await _emit(
      userId: userId,
      type: NotificationType.learningResourceRecommendation,
      context: NotificationContextType.recommendation,
      projectId: projectId,
      boardId: boardId,
      taskId: taskId,
      title: 'Learning resources available',
      message:
          '$resourceCount ${resourceCount == 1 ? 'resource' : 'resources'} may help with “$taskTitle”.',
      uniqueKey: 'recommendation:$taskId:$recommendationBatchId',
      actionData: {
        'resource_count': resourceCount,
        'open_section': 'recommendations',
        if (resourceTitles.isNotEmpty) 'resource_titles': resourceTitles,
      },
    );
  }
}
