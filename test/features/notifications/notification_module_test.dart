import 'package:flutter_test/flutter_test.dart';
import 'package:skilltrack/core/errors/app_exception.dart';
import 'package:skilltrack/features/notifications/models/app_notification.dart';
import 'package:skilltrack/features/notifications/models/notification_context_type.dart';
import 'package:skilltrack/features/notifications/models/notification_preferences.dart';
import 'package:skilltrack/features/notifications/models/notification_type.dart';
import 'package:skilltrack/features/notifications/services/notification_event_coordinator.dart';
import 'package:skilltrack/features/notifications/viewmodels/notification_badge_controller.dart';
import 'package:skilltrack/features/notifications/viewmodels/notification_list_view_model.dart';
import 'package:skilltrack/features/notifications/viewmodels/notification_preferences_view_model.dart';

import '../projects/fake_project_repository.dart';
import '../kanban/fake_repository.dart';
import 'fake_notification_repository.dart';

AppNotification alert(
  String id, {
  NotificationType type = NotificationType.stalledTask,
  bool read = false,
  DateTime? createdAt,
}) => AppNotification(
  id: id,
  userId: 'user',
  type: type,
  contextType: type == NotificationType.deadlineReminder
      ? NotificationContextType.project
      : NotificationContextType.task,
  projectId: 'project',
  boardId: 'board',
  taskId: 'task',
  title: 'Task may be stalled',
  message: 'Task is stalled',
  isRead: read,
  readAt: read ? DateTime.utc(2026, 1) : null,
  createdAt: createdAt ?? DateTime.utc(2026, 1),
);

void main() {
  test(
    'shared error mapping preserves app messages and hides unexpected errors',
    () {
      expect(
        AppException.messageFor(const AppException('Sign in to continue.')),
        'Sign in to continue.',
      );
      expect(
        AppException.messageFor(StateError('internal database detail')),
        AppErrorMessages.requestFailed,
      );
      expect(
        AppException.messageFor(
          Exception('raw response'),
          fallback: AppErrorMessages.saveTagFailed,
        ),
        AppErrorMessages.saveTagFailed,
      );
    },
  );
  test('type and context conversion is controlled', () {
    expect(
      NotificationType.parse('STALLED_TASK'),
      NotificationType.stalledTask,
    );
    expect(
      NotificationType.parse('DEADLINE_REMINDER'),
      NotificationType.deadlineReminder,
    );
    expect(
      NotificationContextType.parse('RECOMMENDATION'),
      NotificationContextType.recommendation,
    );
    expect(NotificationType.parse('unknown'), NotificationType.unknown);
  });

  test('models round trip and defaults', () {
    final value = alert('1');
    expect(AppNotification.fromMap(value.toMap()), value);
    expect(value.isUnread, isTrue);
    expect(
      value.copyWith(isRead: true, readAt: DateTime.utc(2026)).isRead,
      isTrue,
    );
    final defaults = NotificationPreferences.defaults('user');
    expect(defaults.stalledTaskEnabled, isTrue);
    expect(defaults.deadlineReminderEnabled, isTrue);
    expect(defaults.recommendationEnabled, isTrue);
    expect(NotificationPreferences.fromMap(defaults.toMap()).userId, 'user');
  });

  test(
    'repository fake loads only own records, newest first and counts unread',
    () async {
      final repo = FakeNotificationRepository();
      repo.items.addAll([
        alert('older'),
        alert('newer', createdAt: DateTime.utc(2026, 2)),
        AppNotification.fromMap({
          ...alert('other').toMap(),
          'user_id': 'other',
        }),
      ]);
      expect((await repo.getNotifications()).map((e) => e.id), [
        'newer',
        'older',
      ]);
      expect(await repo.getUnreadCount(), 2);
      await repo.markAsRead('older');
      expect(await repo.getUnreadCount(), 1);
      await repo.markAllAsRead();
      expect(await repo.getUnreadCount(), 0);
    },
  );

  test('list load, filters, read, rollback and retry', () async {
    final repo = FakeNotificationRepository()
      ..items.addAll([
        alert('1'),
        alert('2', type: NotificationType.deadlineReminder),
      ]);
    final badge = NotificationBadgeController(repo);
    final model = NotificationListViewModel(
      repo,
      FakeProjectRepository(),
      FakeKanbanRepository(),
      badge,
    );
    await model.initialize();
    expect(model.unreadCount, 2);
    model.setFilter(NotificationListFilter.stalled);
    expect(model.visibleNotifications.length, 1);
    expect(await model.markAsRead('1'), isTrue);
    expect(model.unreadCount, 1);
    repo.failRead = true;
    expect(await model.markAsRead('2'), isFalse);
    expect(model.unreadCount, 1);
    repo.failLoad = true;
    await model.refresh();
    expect(model.errorMessage, isNotNull);
    repo.failLoad = false;
    await model.retry();
    expect(model.errorMessage, isNull);
    model.dispose();
    badge.dispose();
  });

  test('mark all rolls back on failure', () async {
    final repo = FakeNotificationRepository()
      ..items.addAll([alert('1'), alert('2')]);
    final badge = NotificationBadgeController(repo);
    final model = NotificationListViewModel(
      repo,
      FakeProjectRepository(),
      FakeKanbanRepository(),
      badge,
    );
    await model.initialize();
    repo.failAll = true;
    await model.markAllAsRead();
    expect(model.unreadCount, 2);
    expect(model.allNotifications.every((item) => item.isUnread), isTrue);
    repo.failAll = false;
    await model.markAllAsRead();
    expect(model.unreadCount, 0);
    model.dispose();
    badge.dispose();
  });

  test('preferences toggle independently and roll back', () async {
    final repo = FakeNotificationRepository();
    final model = NotificationPreferencesViewModel(repo);
    await model.initialize();
    await model.setStalledTaskEnabled(false);
    expect(model.preferences.stalledTaskEnabled, isFalse);
    expect(model.preferences.deadlineReminderEnabled, isTrue);
    repo.failSave = true;
    await model.setRecommendationEnabled(false);
    expect(model.preferences.recommendationEnabled, isTrue);
    expect(model.errorMessage, isNotNull);
    model.dispose();
  });

  test(
    'coordinator deduplicates, checks preferences and gates invalid events',
    () async {
      final repo = FakeNotificationRepository();
      final events = NotificationEventCoordinator(repo);
      final stalledAt = DateTime.utc(2026, 1);
      Future<void> stalled() => events.notifyTaskStalled(
        userId: 'user',
        projectId: 'project',
        boardId: 'board',
        taskId: 'task',
        taskTitle: 'Study',
        stalledAt: stalledAt,
      );
      await stalled();
      await stalled();
      expect(repo.items.length, 1);
      await events.notifyTaskDeadline(
        userId: 'user',
        projectId: 'project',
        boardId: 'board',
        taskId: 'task',
        taskTitle: 'Study',
        deadline: stalledAt,
        reminderWindow: 'tomorrow',
        isCompleted: true,
      );
      expect(repo.items.length, 1);
      await events.notifyTaskDeadline(
        userId: 'user',
        projectId: 'project',
        boardId: 'board',
        taskId: 'task',
        taskTitle: 'Study',
        deadline: stalledAt,
        reminderWindow: 'tomorrow',
      );
      await events.notifyProjectDeadline(
        userId: 'user',
        projectId: 'project',
        projectName: 'Project',
        deadline: stalledAt,
        reminderWindow: 'in 7 days',
      );
      await events.notifyLearningResourcesAvailable(
        userId: 'user',
        projectId: 'project',
        boardId: 'board',
        taskId: 'task',
        taskTitle: 'Study',
        resourceCount: 0,
        recommendationBatchId: 'batch',
      );
      expect(repo.items.length, 3);
      await events.notifyLearningResourcesAvailable(
        userId: 'user',
        projectId: 'project',
        boardId: 'board',
        taskId: 'task',
        taskTitle: 'Study',
        resourceCount: 2,
        recommendationBatchId: 'batch',
      );
      expect(repo.items.length, 4);
      repo.savedPreferences = NotificationPreferences(
        userId: 'user',
        stalledTaskEnabled: false,
        deadlineReminderEnabled: false,
        recommendationEnabled: false,
      );
      await events.notifyTaskStalled(
        userId: 'user',
        projectId: 'project',
        boardId: 'board',
        taskId: 'next',
        taskTitle: 'Next',
        stalledAt: stalledAt,
      );
      expect(repo.items.length, 4);
    },
  );
}
