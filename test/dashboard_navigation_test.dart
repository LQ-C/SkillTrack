import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skilltrack/features/dashboard/views/home_screen.dart';
import 'package:skilltrack/features/dashboard/repositories/dashboard_repository.dart';
import 'package:skilltrack/features/tutor_management/models/tutor_models.dart';
import 'package:skilltrack/app/router/app_router.dart';
import 'dashboard_view_model_test.dart' show FakeDashboard, project;

class PopulatedDashboard extends FakeDashboard {
  @override
  Future<DashboardProjects> projects(DateTime now) async =>
      DashboardProjects(1, 1, 1, [project()]);
  @override
  Future<MentorshipSession?> session(DateTime now) async =>
      MentorshipSession.fromJson({
        'id': 'session',
        'mentor_id': 'mentor',
        'learner_id': 'first',
        'mentor_name': 'Mentor name',
        'learner_name': 'Learner name',
        'message': '',
        'status': 'accepted',
        'starts_at': now.add(const Duration(days: 1)).toIso8601String(),
        'ends_at': now.add(const Duration(days: 1, hours: 1)).toIso8601String(),
      });
}

void main() {
  testWidgets('project uses existing Kanban board route', (tester) async {
    final repo = PopulatedDashboard();
    final routes = <RouteSettings>[];
    await tester.pumpWidget(
      MaterialApp(
        onGenerateRoute: (settings) {
          routes.add(settings);
          return MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Detail')),
          );
        },
        home: HomeScreen(
          repository: repo,
          loadProfile: () async => {'full_name': 'Alex', 'role': 'student'},
          onProfile: () async {},
          onLibrary: (_) async {},
          onMentorship: () async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    final taskCard = find.text('Project');
    await tester.scrollUntilVisible(
      taskCard,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('25% complete · 1 of 4 tasks'), findsOneWidget);
    expect(find.text('1 stalled tasks'), findsOneWidget);
    await tester.tap(taskCard);
    await tester.pumpAndSettle();
    expect(routes.last.name, AppRoutes.kanbanBoard);
    expect((routes.last.arguments as BoardRouteArgs).boardId, 'b');
    expect((routes.last.arguments as BoardRouteArgs).projectId, 'p');
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await repo.changes.close();
  });
  testWidgets(
    'combined dashboard preserves section order and original shortcuts',
    (tester) async {
      tester.view.physicalSize = const Size(600, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repo = PopulatedDashboard();
      var library = 0, mentorship = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(
            repository: repo,
            loadProfile: () async => {'full_name': 'Alex', 'role': 'student'},
            onProfile: () async {},
            onLibrary: (_) async {
              library++;
            },
            onMentorship: () async {
              mentorship++;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      final labels = [
        'Welcome back, Alex',
        'Small steps.\nReal skills.',
        'Project overview',
        'Your projects',
        'Make it your own',
        'Upcoming session',
      ];
      double previous = -1;
      for (final label in labels) {
        final y = tester.getTopLeft(find.text(label)).dy;
        expect(y, greaterThan(previous));
        previous = y;
      }
      expect(find.text('Quick actions'), findsNothing);
      expect(find.text('Task-bookmarked resources'), findsNothing);
      await tester.tap(find.text('Browse resources'));
      await tester.pumpAndSettle();
      expect(library, 1);
      await tester.tap(find.text('Open mentorship'));
      await tester.pumpAndSettle();
      expect(mentorship, 1);
      await tester.pumpWidget(const SizedBox());
      await repo.changes.close();
    },
  );
  testWidgets('empty projects offer creation and View all selects Project', (
    tester,
  ) async {
    final repo = FakeDashboard();
    var selected = false;
    final routes = <String?>[];
    await tester.pumpWidget(
      MaterialApp(
        onGenerateRoute: (settings) {
          routes.add(settings.name);
          return MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Create form')),
          );
        },
        home: HomeScreen(
          repository: repo,
          loadProfile: () async => {},
          onProfile: () async {},
          onLibrary: (_) async {},
          onProjects: () async {
            selected = true;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('View all').hitTestable(), 200);
    await tester.tap(find.text('View all'));
    await tester.pumpAndSettle();
    expect(selected, true);
    await tester.scrollUntilVisible(
      find.text('Create your first project').hitTestable(),
      200,
    );
    await tester.tap(find.text('Create your first project'));
    await tester.pumpAndSettle();
    expect(routes.last, AppRoutes.createProject);
    await tester.pumpWidget(const SizedBox());
    await repo.changes.close();
  });
  testWidgets('overview fits narrow screens with enlarged text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repo = FakeDashboard();
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: HomeScreen(
          repository: repo,
          loadProfile: () async => {},
          onProfile: () async {},
          onLibrary: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (final label in [
      'Active projects',
      'Tasks due today',
      'Stalled tasks',
    ]) {
      await tester.scrollUntilVisible(
        find.text(label).hitTestable(),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text(label), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox());
    await repo.changes.close();
  });
  for (final mentor in [false, true]) {
    testWidgets('session shows correct participant for mentor=$mentor', (
      tester,
    ) async {
      final repo = PopulatedDashboard();
      if (mentor) repo.userId = 'mentor';
      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(
            repository: repo,
            loadProfile: () async => {'role': mentor ? 'mentor' : 'student'},
            onProfile: () async {},
            onLibrary: (_) async {},
            onMentorship: () async {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text(mentor ? 'Learner: Learner name' : 'Mentor: Mentor name'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.text(mentor ? 'Learner: Learner name' : 'Mentor: Mentor name'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
      await repo.changes.close();
    });
  }
  testWidgets('duplicate banner action taps open only once', (tester) async {
    final pending = Completer<void>();
    var opens = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          loadProfile: () async => {},
          onProfile: () async {},
          onLibrary: (_) {
            opens++;
            return pending.future;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Explore the library'));
    await tester.tap(find.text('Explore the library'));
    expect(opens, 1);
    pending.complete();
    await tester.pumpAndSettle();
  });
}
