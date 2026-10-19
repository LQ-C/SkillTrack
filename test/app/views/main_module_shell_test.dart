import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:skilltrack/app/router/app_router.dart';
import 'package:skilltrack/app/skill_track_app.dart';
import 'package:skilltrack/app/views/main_module_shell.dart';
import 'package:skilltrack/features/kanban/models/kanban_status.dart';
import 'package:skilltrack/app/widgets/skilltrack_bottom_navigation.dart';
import 'package:skilltrack/features/notifications/models/app_notification.dart';
import 'package:skilltrack/features/notifications/models/notification_context_type.dart';
import 'package:skilltrack/features/notifications/models/notification_type.dart';
import 'package:skilltrack/features/notifications/services/notification_realtime_service.dart';
import 'package:skilltrack/features/notifications/viewmodels/notification_badge_controller.dart';
import 'package:skilltrack/features/notifications/viewmodels/notification_list_view_model.dart';
import 'package:skilltrack/features/notifications/views/notification_screen.dart';
import 'package:skilltrack/features/projects/models/project_with_progress.dart';
import 'package:skilltrack/features/projects/views/project_dashboard_screen.dart';

import '../../features/kanban/fake_repository.dart';
import '../../features/notifications/fake_notification_repository.dart';
import '../../features/projects/fake_project_repository.dart';

class _Projects extends FakeProjectRepository {
  _Projects({super.items});
  int loads = 0;

  @override
  Future<List<ProjectWithProgress>> getProjectsWithProgress() {
    loads++;
    return super.getProjectsWithProgress();
  }
}

class _Notifications extends FakeNotificationRepository {
  int loads = 0;

  @override
  Future<List<AppNotification>> getNotifications({
    int limit = 50,
    DateTime? before,
    String? beforeId,
  }) {
    loads++;
    return super.getNotifications(
      limit: limit,
      before: before,
      beforeId: beforeId,
    );
  }
}

class _Transport implements NotificationRealtimeTransport {
  int starts = 0, stops = 0;
  void Function(PostgresChangePayload)? onPayload;

  @override
  Future<void> subscribeForUser(
    String userId,
    void Function(PostgresChangePayload) onPayload,
    void Function(RealtimeSubscribeStatus) onStatus,
  ) async {
    starts++;
    this.onPayload = onPayload;
    onStatus(RealtimeSubscribeStatus.subscribed);
  }

  @override
  Future<void> unsubscribe() async {
    stops++;
    onPayload = null;
  }

  void insert(AppNotification item) => onPayload!(
    PostgresChangePayload(
      schema: 'public',
      table: 'notifications',
      commitTimestamp: DateTime.now().toUtc(),
      eventType: PostgresChangeEvent.insert,
      newRecord: item.toMap(),
      oldRecord: const {},
      errors: null,
    ),
  );
}

AppNotification _notification(String id, {bool task = false, DateTime? date}) =>
    AppNotification(
      id: id,
      userId: 'user',
      type: NotificationType.deadlineReminder,
      contextType: task
          ? NotificationContextType.task
          : NotificationContextType.project,
      projectId: '1',
      boardId: 'board-1',
      taskId: task ? 'task-1' : null,
      title: 'Deadline alert $id',
      message: 'Due soon',
      createdAt: date ?? DateTime.now().toUtc(),
    );

Finder _destination(String label) => find.descendant(
  of: find.byType(SkillTrackBottomNavigation),
  matching: find.text(label),
);

int _selectedIndex(WidgetTester tester) =>
    tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex;

Future<void> _tapModule(WidgetTester tester, String label) async {
  await tester.tap(_destination(label));
  await tester.pumpAndSettle();
}

Future<void> _swipe(WidgetTester tester, double direction) async {
  await tester.drag(find.byType(PageView), Offset(direction * 320, 0));
  await tester.pumpAndSettle();
}

Future<void> _showApp(
  WidgetTester tester, {
  _Projects? projects,
  _Notifications? notifications,
  FakeKanbanRepository? kanban,
  NotificationRealtimeService? realtime,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    SkillTrackApp(
      projectRepository: projects ?? _Projects(),
      kanbanRepository: kanban ?? FakeKanbanRepository(),
      notificationRepository: notifications ?? _Notifications(),
      realtimeService: realtime,
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('starts on Projects with one fixed navigation bar', (
    tester,
  ) async {
    await _showApp(tester);
    expect(_selectedIndex(tester), 2);
    expect(find.text('My Projects').hitTestable(), findsOneWidget);
    expect(find.byType(SkillTrackBottomNavigation), findsOneWidget);
    expect(
      tester.widget<PageView>(find.byType(PageView)).physics,
      isA<PageScrollPhysics>(),
    );
    final barRect = tester.getRect(find.byType(NavigationBar));
    final context = tester.element(find.byType(MainModuleShell));
    expect(Navigator.of(context).canPop(), isFalse);
    await tester.drag(find.byType(PageView), const Offset(-240, 0));
    await tester.pump(const Duration(milliseconds: 30));
    expect(tester.getRect(find.byType(NavigationBar)), barRect);
    await tester.pumpAndSettle();
    expect(_selectedIndex(tester), 3);
    expect(find.text('No notifications yet').hitTestable(), findsOneWidget);
    expect(find.byType(SkillTrackBottomNavigation), findsOneWidget);
    await _swipe(tester, 1);
    expect(_selectedIndex(tester), 2);
    expect(find.text('My Projects').hitTestable(), findsOneWidget);
    expect(Navigator.of(context).canPop(), isFalse);
    await _swipe(tester, 1);
    expect(_selectedIndex(tester), 2);
  });

  testWidgets('bottom destinations animate the existing page controller', (
    tester,
  ) async {
    await _showApp(tester);
    final controller = tester
        .widget<PageView>(find.byType(PageView))
        .controller!;
    await tester.tap(_destination('Notifications'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(controller.page, inExclusiveRange(0, 1));
    await tester.pumpAndSettle();
    expect(_selectedIndex(tester), 3);
    expect(controller.page, 1);
    await _tapModule(tester, 'Notifications');
    expect(controller.page, 1);
    await _tapModule(tester, 'Project');
    expect(_selectedIndex(tester), 2);
    expect(
      tester.widget<PageView>(find.byType(PageView)).controller,
      same(controller),
    );
    expect(find.byType(MainModuleShell), findsOneWidget);
    expect(
      Navigator.of(tester.element(find.byType(MainModuleShell))).canPop(),
      isFalse,
    );
  });

  testWidgets('unavailable destinations show feedback without changing pages', (
    tester,
  ) async {
    await _showApp(tester);
    for (final label in ['Home', 'Marketplace', 'Profile']) {
      await _tapModule(tester, label);
      expect(
        find.text('$label is not available in this prototype.'),
        findsOneWidget,
      );
      expect(_selectedIndex(tester), 2);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    }
    await _tapModule(tester, 'Notifications');
    await _tapModule(tester, 'Home');
    expect(
      find.text('Home is not available in this prototype.'),
      findsOneWidget,
    );
    expect(_selectedIndex(tester), 3);
    await _swipe(tester, -1);
    expect(_selectedIndex(tester), 3);
  });

  testWidgets(
    'swipes preserve search, filtering, pagination and scroll position',
    (tester) async {
      final projects = _Projects(
        items: [sampleProject('1', 'Flutter'), sampleProject('2', 'Dart')],
      );
      final notifications = _Notifications();
      final newest = DateTime.now().toUtc();
      notifications.items.addAll(
        List.generate(
          51,
          (index) => _notification(
            '$index',
            date: newest.subtract(Duration(minutes: index)),
          ),
        ),
      );
      await _showApp(tester, projects: projects, notifications: notifications);
      await tester.tap(find.byTooltip('Search projects'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Flutter');
      tester.testTextInput.hide();
      await tester.pumpAndSettle();
      await _swipe(tester, -1);
      final screen = tester.widget<NotificationScreen>(
        find.byType(NotificationScreen),
      );
      final model = screen.viewModel;
      await tester.tap(find.text('Unread 51'));
      await tester.pumpAndSettle();
      final scrollable = find
          .descendant(
            of: find.byType(NotificationScreen),
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is Scrollable &&
                  widget.axisDirection == AxisDirection.down,
            ),
          )
          .first;
      await tester.scrollUntilVisible(
        find.text('Load older notifications'),
        500,
        scrollable: scrollable,
      );
      await tester.tap(find.text('Load older notifications'));
      await tester.pumpAndSettle();
      expect(model.allNotifications.length, 51);
      final scrollOffset = tester
          .state<ScrollableState>(scrollable)
          .position
          .pixels;
      expect(scrollOffset, greaterThan(0));
      await _swipe(tester, 1);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Flutter',
      );
      expect(find.text('Dart').hitTestable(), findsNothing);
      await _swipe(tester, -1);
      expect(
        tester
            .widget<NotificationScreen>(find.byType(NotificationScreen))
            .viewModel,
        same(model),
      );
      expect(model.selectedFilter, NotificationListFilter.unread);
      expect(model.allNotifications.length, 51);
      expect(
        tester.state<ScrollableState>(scrollable).position.pixels,
        scrollOffset,
      );
      expect(projects.loads, 1);
      expect(notifications.loads, 2);
    },
  );

  testWidgets('keeps shared Realtime and badge alive while changing pages', (
    tester,
  ) async {
    final transport = _Transport();
    final realtime = NotificationRealtimeService(transport);
    final notifications = _Notifications();
    await _showApp(tester, notifications: notifications, realtime: realtime);
    final shell = tester.widget<MainModuleShell>(find.byType(MainModuleShell));
    expect(shell.realtime, same(realtime));
    await _swipe(tester, -1);
    final model = tester
        .widget<NotificationScreen>(find.byType(NotificationScreen))
        .viewModel;
    await _swipe(tester, 1);
    final fresh = _notification('fresh');
    notifications.items.add(fresh);
    transport.insert(fresh);
    await tester.pumpAndSettle();
    expect(shell.badgeController.unreadCount, 1);
    await _swipe(tester, -1);
    expect(find.text('Deadline alert fresh').hitTestable(), findsOneWidget);
    expect(
      tester
          .widget<NotificationScreen>(find.byType(NotificationScreen))
          .viewModel,
      same(model),
    );
    expect(
      tester
          .widget<ProjectDashboardScreen>(
            find.byType(ProjectDashboardScreen, skipOffstage: false),
          )
          .badgeController,
      same(shell.badgeController),
    );
    expect(transport.starts, 1);
    expect(notifications.loads, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(transport.stops, 1);
  });

  testWidgets('project notification switches the same shell to Projects', (
    tester,
  ) async {
    final notifications = _Notifications()..items.add(_notification('project'));
    final projects = _Projects(
      items: [sampleProject('1', 'Flutter', boardId: 'board-1')],
    );
    await _showApp(tester, projects: projects, notifications: notifications);
    await _tapModule(tester, 'Notifications');
    final state = tester.state(find.byType(MainModuleShell));
    await tester.tap(find.text('Deadline alert project'));
    await tester.pumpAndSettle();
    expect(_selectedIndex(tester), 2);
    expect(tester.state(find.byType(MainModuleShell)), same(state));
    expect(find.byType(MainModuleShell), findsOneWidget);
    expect(find.text('Flutter').hitTestable(), findsOneWidget);
    expect(notifications.items.single.isRead, isTrue);
    expect(notifications.loads, 1);
  });

  testWidgets(
    'task details and preferences return to the selected Notification page',
    (tester) async {
      final notifications = _Notifications()
        ..items.add(_notification('task', task: true));
      final projects = _Projects(
        items: [sampleProject('1', 'Flutter', boardId: 'board-1')],
      );
      final kanban = FakeKanbanRepository(
        tasks: [sampleTask('task-1', 'Study', KanbanStatus.todo)],
      );
      await _showApp(
        tester,
        projects: projects,
        notifications: notifications,
        kanban: kanban,
      );
      await _tapModule(tester, 'Notifications');
      await tester.tap(find.text('Deadline alert task'));
      await tester.pumpAndSettle();
      expect(find.text('Task Details'), findsOneWidget);
      expect(find.text('Study'), findsOneWidget);
      expect(notifications.items.single.isRead, isTrue);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(_selectedIndex(tester), 3);
      await tester.tap(find.byTooltip('Notification preferences'));
      await tester.pumpAndSettle();
      expect(find.text('Notification Preferences'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(_selectedIndex(tester), 3);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(_selectedIndex(tester), 2);
      expect(
        tester.widget<PopScope<Object?>>(find.byType(PopScope<Object?>)).canPop,
        isTrue,
      );
    },
  );

  testWidgets(
    'direct Notifications route starts on page one and Back selects Projects',
    (tester) async {
      final notifications = _Notifications()
        ..items.add(_notification('direct'));
      final badge = NotificationBadgeController(notifications);
      final router = AppRouter(
        projectRepository: _Projects(items: [sampleProject('1', 'Flutter')]),
        kanbanRepository: FakeKanbanRepository(),
        notificationRepository: notifications,
        badgeController: badge,
      );
      await tester.pumpWidget(
        MaterialApp(
          initialRoute: AppRoutes.notifications,
          onGenerateInitialRoutes: (name) => [
            router.onGenerateRoute(RouteSettings(name: name)),
          ],
          onGenerateRoute: router.onGenerateRoute,
        ),
      );
      await tester.pumpAndSettle();
      expect(_selectedIndex(tester), 3);
      expect(
        tester.widget<PageView>(find.byType(PageView)).controller!.page,
        1,
      );
      expect(find.byType(SkillTrackBottomNavigation), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(_selectedIndex(tester), 2);
      expect(
        Navigator.of(tester.element(find.byType(MainModuleShell))).canPop(),
        isFalse,
      );
      await _tapModule(tester, 'Notifications');
      await tester.tap(find.text('Deadline alert direct'));
      await tester.pumpAndSettle();
      expect(_selectedIndex(tester), 2);
      expect(find.byType(MainModuleShell), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      badge.dispose();
    },
  );

  testWidgets('project forms and Kanban open above the retained shell', (
    tester,
  ) async {
    final projects = _Projects(items: [sampleProject('1', 'Flutter')]);
    await _showApp(tester, projects: projects);
    final shellState = tester.state(find.byType(MainModuleShell));
    await tester.tap(find.byKey(const Key('new-project-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('project-name-field')), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('project-1')));
    await tester.pumpAndSettle();
    expect(find.text('Kanban Board'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(tester.state(find.byType(MainModuleShell)), same(shellState));
    expect(_selectedIndex(tester), 2);
    expect(find.byType(SkillTrackBottomNavigation), findsOneWidget);
  });
}
