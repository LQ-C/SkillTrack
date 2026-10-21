import 'dart:async';
import 'package:skilltrack/features/notifications/widgets/notification_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skilltrack/app/skill_track_app.dart';
import 'package:skilltrack/features/notifications/models/app_notification.dart';
import 'package:skilltrack/features/notifications/models/notification_context_type.dart';
import 'package:skilltrack/features/notifications/models/notification_type.dart';
import 'package:skilltrack/features/kanban/models/kanban_status.dart';
import 'package:skilltrack/features/kanban/models/kanban_task.dart';
import 'package:skilltrack/features/kanban/models/task_priority.dart';
import 'package:skilltrack/features/projects/models/learning_project.dart';
import 'package:skilltrack/features/projects/models/project_with_progress.dart';

import '../kanban/fake_repository.dart';
import '../projects/fake_project_repository.dart';
import 'fake_notification_repository.dart';

AppNotification item(
  String id, {
  bool read = false,
  NotificationContextType context = NotificationContextType.project,
}) => AppNotification(
  id: id,
  userId: 'user',
  type: NotificationType.deadlineReminder,
  contextType: context,
  projectId: 'project',
  boardId: 'board',
  taskId: context == NotificationContextType.task ? 'task' : null,
  title: 'Project deadline approaching',
  message: 'Due tomorrow',
  isRead: read,
  readAt: read ? DateTime.utc(2026, 1) : null,
  createdAt: DateTime.now().toUtc(),
);

Future<void> showApp(
  WidgetTester tester,
  FakeNotificationRepository notifications, {
  FakeProjectRepository? projects,
  FakeKanbanRepository? kanban,
  Size size = const Size(390, 844),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    SkillTrackApp(
      projectRepository: projects ?? FakeProjectRepository(),
      kanbanRepository: kanban ?? FakeKanbanRepository(),
      notificationRepository: notifications,
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('Notifications'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'notification taps share one navigation lock and failure allows retry',
    (tester) async {
      final repo = _PendingReadRepository()
        ..items.addAll([item('a'), item('b')]);
      await showApp(tester, repo);
      final tiles = tester
          .widgetList<NotificationTile>(find.byType(NotificationTile))
          .toList();
      final first = tiles[0].onTap!;
      final second = tiles[1].onTap!;
      first();
      first();
      second();
      expect(repo.readCalls, 1);
      await tester.pump();
      expect(
        tester
            .widgetList<NotificationTile>(find.byType(NotificationTile))
            .every((tile) => tile.onTap == null),
        isTrue,
      );
      repo.pendingRead!.completeError(StateError('offline'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<NotificationTile>(find.byType(NotificationTile))
            .every((tile) => tile.onTap != null),
        isTrue,
      );
      repo.pendingRead = null;
      await tester.tap(find.byKey(const Key('notification-a')));
      await tester.pumpAndSettle();
      expect(repo.readCalls, 2);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('repeated settings callback opens one preference route', (
    tester,
  ) async {
    await showApp(tester, FakeNotificationRepository());
    final open = tester
        .widget<IconButton>(
          find.byWidgetPredicate(
            (widget) =>
                widget is IconButton &&
                widget.tooltip == 'Notification preferences',
          ),
        )
        .onPressed!;
    open();
    open();
    await tester.pumpAndSettle();
    expect(find.text('Notification Preferences'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (widget) =>
                  widget is IconButton &&
                  widget.tooltip == 'Notification preferences',
            ),
          )
          .onPressed,
      isNotNull,
    );
  });

  testWidgets(
    'unknown notification type displays a safe fallback alongside known types',
    (tester) async {
      final unknown = AppNotification.fromMap({
        ...item('future').toMap(),
        'type': 'FUTURE_ALERT',
        'title': 'New notification type',
        'message': 'Future alert message',
      });
      final repo = FakeNotificationRepository()
        ..items.addAll([unknown, item('known')]);
      await showApp(tester, repo);
      expect(find.text('New notification type'), findsOneWidget);
      expect(find.text('Future alert message'), findsOneWidget);
      expect(find.byIcon(Icons.notifications_none), findsOneWidget);
      expect(find.text('Project deadline approaching'), findsOneWidget);
      expect(find.byKey(const Key('unread-dot')), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'stalled notification for an archived task stays on notifications',
    (tester) async {
      final alert = AppNotification.fromMap({
        ...item('archived', context: NotificationContextType.task).toMap(),
        'type': 'STALLED_TASK',
      });
      final repo = FakeNotificationRepository()..items.add(alert);
      final projects = FakeProjectRepository(
        items: [
          ProjectWithProgress(
            project: const LearningProject(
              id: 'project',
              ownerId: 'user-1',
              name: 'Demo Project',
              status: 'active',
            ),
            boardId: 'board',
            totalTaskCount: 1,
            completedTaskCount: 0,
          ),
        ],
      );
      final now = DateTime.utc(2026, 10, 13);
      final kanban = FakeKanbanRepository(
        tasks: [
          KanbanTask(
            id: 'task',
            boardId: 'board',
            title: 'Archived task',
            status: KanbanStatus.todo,
            priority: TaskPriority.medium,
            sortOrder: 1000,
            isArchived: true,
            createdAt: now,
            updatedAt: now,
          ),
        ],
      );
      await showApp(tester, repo, projects: projects, kanban: kanban);
      await tester.tap(find.text('Project deadline approaching'));
      await tester.pumpAndSettle();
      expect(find.text('This item is no longer available.'), findsOneWidget);
      expect(find.text('Task Details'), findsNothing);
      expect(await repo.getUnreadCount(), 0);
    },
  );

  testWidgets('notification tab opens empty state and preferences', (
    tester,
  ) async {
    final repo = FakeNotificationRepository();
    await showApp(tester, repo);
    expect(find.text('No notifications yet'), findsOneWidget);
    await tester.tap(
      find.byWidgetPredicate(
        (widget) =>
            widget is IconButton &&
            widget.tooltip == 'Notification preferences',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Notification Preferences'), findsOneWidget);
    expect(find.byType(SwitchListTile), findsNWidgets(4));
    await tester.tap(
      find.widgetWithText(SwitchListTile, 'Stalled task alerts'),
    );
    await tester.pumpAndSettle();
    expect((await repo.getPreferences()).stalledTaskEnabled, isFalse);
  });

  testWidgets('unread tile, filter, mark all, and badge update', (
    tester,
  ) async {
    final repo = FakeNotificationRepository()
      ..items.addAll([item('1'), item('2', read: true)]);
    await showApp(tester, repo);
    expect(find.byKey(const Key('unread-dot')), findsOneWidget);
    expect(find.text('Unread 1'), findsOneWidget);
    await tester.tap(find.text('Unread 1'));
    await tester.pumpAndSettle();
    expect(find.byType(Card), findsOneWidget);
    await tester.tap(find.byTooltip('Notification actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mark all as read'));
    await tester.pumpAndSettle();
    expect(find.text('You’re all caught up'), findsOneWidget);
    expect(find.byKey(const Key('unread-dot')), findsNothing);
    expect(await repo.getUnreadCount(), 0);
  });

  testWidgets('missing project stays on notifications after read', (
    tester,
  ) async {
    final repo = FakeNotificationRepository()..items.add(item('1'));
    await showApp(tester, repo);
    await tester.tap(find.text('Project deadline approaching'));
    await tester.pumpAndSettle();
    expect(find.text('This item is no longer available.'), findsOneWidget);
    expect(find.text('Notifications'), findsWidgets);
    expect(await repo.getUnreadCount(), 0);
  });

  testWidgets('project notification returns to the project dashboard', (
    tester,
  ) async {
    final repo = FakeNotificationRepository()
      ..items.add(
        AppNotification.fromMap({...item('1').toMap(), 'board_id': null}),
      );
    final projects = FakeProjectRepository(
      items: [
        ProjectWithProgress(
          project: const LearningProject(
            id: 'project',
            ownerId: 'user-1',
            name: 'Demo Project',
            status: 'active',
          ),
          boardId: 'board',
          totalTaskCount: 0,
          completedTaskCount: 0,
        ),
      ],
    );
    await showApp(tester, repo, projects: projects);
    await tester.tap(find.text('Project deadline approaching'));
    await tester.pumpAndSettle();
    expect(find.text('My Projects'), findsOneWidget);
    expect(find.text('Demo Project'), findsOneWidget);
    expect(await repo.getUnreadCount(), 0);
  });

  testWidgets('task notification opens Task Details and marks read', (
    tester,
  ) async {
    final repo = FakeNotificationRepository()
      ..items.add(item('1', context: NotificationContextType.task));
    final projects = FakeProjectRepository(
      items: [
        ProjectWithProgress(
          project: const LearningProject(
            id: 'project',
            ownerId: 'user-1',
            name: 'Demo Project',
            status: 'active',
          ),
          boardId: 'board',
          totalTaskCount: 1,
          completedTaskCount: 0,
        ),
      ],
    );
    final now = DateTime.utc(2026, 1);
    final kanban = FakeKanbanRepository(
      tasks: [
        KanbanTask(
          id: 'task',
          boardId: 'board',
          title: 'Study',
          status: KanbanStatus.inProgress,
          priority: TaskPriority.medium,
          sortOrder: 1000,
          createdAt: now,
          updatedAt: now,
        ),
      ],
    );
    await showApp(tester, repo, projects: projects, kanban: kanban);
    await tester.tap(find.text('Project deadline approaching'));
    await tester.pumpAndSettle();
    expect(find.text('Task Details'), findsOneWidget);
    expect(find.text('Study'), findsOneWidget);
    expect(await repo.getUnreadCount(), 0);
  });

  testWidgets('stalled alert opens details and persists Resume', (
    tester,
  ) async {
    final stalled = AppNotification.fromMap({
      ...item('1', context: NotificationContextType.task).toMap(),
      'type': 'STALLED_TASK',
      'title': 'Task may be stalled',
    });
    final repo = FakeNotificationRepository()..items.add(stalled);
    final projects = FakeProjectRepository(
      items: [
        ProjectWithProgress(
          project: const LearningProject(
            id: 'project',
            ownerId: 'user-1',
            name: 'Demo Project',
            status: 'active',
          ),
          boardId: 'board',
          totalTaskCount: 1,
          completedTaskCount: 0,
        ),
      ],
    );
    final now = DateTime.utc(2026, 1);
    final kanban = FakeKanbanRepository(
      tasks: [
        KanbanTask(
          id: 'task',
          boardId: 'board',
          title: 'Study',
          status: KanbanStatus.inProgress,
          priority: TaskPriority.medium,
          sortOrder: 1000,
          createdAt: now,
          updatedAt: now,
          stagnationScore: 80,
          isStalled: true,
          stagnationCheckedAt: now,
        ),
      ],
    );
    await showApp(tester, repo, projects: projects, kanban: kanban);
    await tester.tap(find.text('Task may be stalled'));
    await tester.pumpAndSettle();
    expect(find.text('Task marked as stalled'), findsOneWidget);
    expect(find.textContaining('/100'), findsNothing);
    await tester.tap(find.text('Resume Task'));
    await tester.pumpAndSettle();
    expect(kanban.activityEvents.single.action, 'resumed');
    expect(find.text('Task marked as stalled'), findsNothing);
    expect(kanban.stored.single.isStalled, isFalse);
    expect(kanban.stored.single.stagnationScore, 0);
    expect(await repo.getUnreadCount(), 0);
  });

  testWidgets(
    'recommendation opens Task Details without resource placeholders',
    (tester) async {
      final recommendation = AppNotification.fromMap({
        ...item('1', context: NotificationContextType.task).toMap(),
        'type': 'LEARNING_RESOURCE_RECOMMENDATION',
        'context_type': 'RECOMMENDATION',
        'action_data': {
          'resource_count': 1,
          'resource_titles': ['Flutter layout guide'],
        },
      });
      final repo = FakeNotificationRepository()..items.add(recommendation);
      final projects = FakeProjectRepository(
        items: [
          ProjectWithProgress(
            project: const LearningProject(
              id: 'project',
              ownerId: 'user-1',
              name: 'Demo Project',
              status: 'active',
            ),
            boardId: 'board',
            totalTaskCount: 1,
            completedTaskCount: 0,
          ),
        ],
      );
      final now = DateTime.utc(2026, 1);
      final kanban = FakeKanbanRepository(
        tasks: [
          KanbanTask(
            id: 'task',
            boardId: 'board',
            title: 'Study',
            status: KanbanStatus.inProgress,
            priority: TaskPriority.medium,
            sortOrder: 1000,
            createdAt: now,
            updatedAt: now,
          ),
        ],
      );
      await showApp(tester, repo, projects: projects, kanban: kanban);
      await tester.tap(find.text('Project deadline approaching'));
      await tester.pumpAndSettle();
      expect(find.text('Task Details'), findsOneWidget);
      expect(find.text('Study'), findsOneWidget);
      expect(find.text('Recommended Learning Resources'), findsNothing);
      expect(find.text('Flutter layout guide'), findsNothing);
    },
  );

  testWidgets('compact screen does not overflow', (tester) async {
    final repo = FakeNotificationRepository()..items.add(item('1'));
    await showApp(tester, repo, size: const Size(320, 700));
    expect(tester.takeException(), isNull);
  });
}

class _PendingReadRepository extends FakeNotificationRepository {
  Completer<void>? pendingRead = Completer<void>();
  int readCalls = 0;

  @override
  Future<void> markAsRead(String id) async {
    readCalls++;
    await pendingRead?.future;
    await super.markAsRead(id);
  }
}
