import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skilltrack/app/skill_track_app.dart';
import 'package:skilltrack/app/views/main_module_shell.dart';
import 'package:skilltrack/app/marketplace_dependencies.dart';
import 'package:skilltrack/app/router/app_router.dart';
import 'package:skilltrack/app/app_theme.dart';
import 'package:skilltrack/features/authentication/services/account_service.dart';
import 'package:skilltrack/features/notifications/viewmodels/notification_badge_controller.dart';
import 'package:skilltrack/features/notifications/views/notification_screen.dart';
import 'package:skilltrack/features/educational_content/views/resource_detail.dart';
import '../../features/projects/fake_project_repository.dart';
import '../../features/kanban/fake_repository.dart';
import '../../features/notifications/fake_notification_repository.dart';
import '../../marketplace/content_test.dart' show FakeContentRepository;
import '../../marketplace/tutor_management_test.dart' show MemoryTutors;

class Accounts extends AccountService {
  @override
  bool get emailVerified => true;
  @override
  String? get email => "fixture@example.test";
  @override
  Future<Map<String, dynamic>> loadProfile() async => {
    'full_name': 'Test Student',
    'date_of_birth': '2000-01-01',
    'role': 'student',
    'bio': '',
  };
}

Future<void> showShell(WidgetTester tester) async {
  final notifications = FakeNotificationRepository();
  final projects = FakeProjectRepository();
  final kanban = FakeKanbanRepository();
  final badge = NotificationBadgeController(notifications);
  final marketplace = MarketplaceDependencies.inject(
    accounts: Accounts(),
    content: FakeContentRepository(),
    tutors: MemoryTutors(),
  );
  final router = AppRouter(
    projectRepository: projects,
    kanbanRepository: kanban,
    notificationRepository: notifications,
    badgeController: badge,
    marketplace: marketplace,
  );
  addTearDown(badge.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light,
      onGenerateRoute: router.onGenerateRoute,
      home: MainModuleShell(
        projectRepository: projects,
        kanbanRepository: kanban,
        notificationRepository: notifications,
        badgeController: badge,
        marketplace: marketplace,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> tab(WidgetTester tester, String label) async {
  await tester.tap(
    find
        .descendant(of: find.byType(NavigationBar), matching: find.text(label))
        .first,
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('five real tabs retain one shell and project search', (
    tester,
  ) async {
    await showShell(tester);
    for (final name in ['Home', 'Explore', 'Library', 'Project', 'Profile']) {
      await tab(tester, name);
      expect(find.byType(MainModuleShell), findsOneWidget);
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byTooltip('Notifications').hitTestable(), findsOneWidget);
    }
    await tab(tester, 'Project');
    await tester.tap(find.byTooltip('Search projects'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Retained query');
    await tab(tester, 'Home');
    await tab(tester, 'Project');
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'Retained query',
    );
  });
  testWidgets(
    'bell opens one inbox above retained shell and back restores tab',
    (tester) async {
      await showShell(tester);
      await tab(tester, 'Library');
      final bell = tester.widget<IconButton>(
        find
            .ancestor(
              of: find.byTooltip('Notifications').hitTestable(),
              matching: find.byType(IconButton),
            )
            .first,
      );
      bell.onPressed!();
      bell.onPressed!();
      await tester.pumpAndSettle();
      expect(find.byType(NotificationScreen), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        2,
      );
    },
  );
  testWidgets(
    'repeated tab taps keep the same library and selected back returns home',
    (tester) async {
      await showShell(tester);
      await tab(tester, 'Library');
      final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
      bar.onDestinationSelected!(2);
      bar.onDestinationSelected!(2);
      await tester.pumpAndSettle();
      expect(find.byType(MainModuleShell), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        0,
      );
    },
  );
  testWidgets(
    'recommendation destination uses actual resource detail repository',
    (tester) async {
      await showShell(tester);
      await tab(tester, 'Library');
      final context = tester.element(find.byType(MainModuleShell));
      AppRouter.resourceDetails(context, 'one');
      await tester.pumpAndSettle();
      expect(find.byType(ResourceDetail), findsOneWidget);
      expect(find.text('Flutter login guide'), findsOneWidget);
    },
  );
  testWidgets('test app without account dependencies starts project module', (
    tester,
  ) async {
    await tester.pumpWidget(
      SkillTrackApp(
        projectRepository: FakeProjectRepository(),
        kanbanRepository: FakeKanbanRepository(),
        notificationRepository: FakeNotificationRepository(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('My Projects'), findsOneWidget);
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      3,
    );
  });
}
