import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skilltrack/app/skill_track_app.dart';
import 'package:skilltrack/app/router/app_router.dart';
import 'package:skilltrack/features/kanban/models/kanban_status.dart';

import '../kanban/fake_repository.dart';
import 'fake_project_repository.dart';

void main() {
  Future<void> showApp(
    WidgetTester tester,
    FakeProjectRepository projects, {
    FakeKanbanRepository? kanban,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      SkillTrackApp(
        projectRepository: projects,
        kanbanRepository: kanban ?? FakeKanbanRepository(),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('Project tab starts on dashboard and empty state opens form', (
    tester,
  ) async {
    await showApp(tester, FakeProjectRepository());
    expect(find.text('My Projects'), findsOneWidget);
    expect(
      Navigator.of(tester.element(find.text('My Projects'))).canPop(),
      false,
    );
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      2,
    );
    expect(find.text('No projects yet'), findsOneWidget);
    await tester.tap(find.text('Create Project'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('project-name-field')), findsOneWidget);
    await tester.tap(find.byKey(const Key('save-project-button')));
    await tester.pumpAndSettle();
    expect(find.text('Project name is required.'), findsOneWidget);
  });

  testWidgets('signing in closes the dialog and loads the dashboard', (
    tester,
  ) async {
    final projects = FakeProjectRepository(userId: null);
    await showApp(tester, projects);
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'test@example.com');
    await tester.enterText(find.byType(TextField).last, 'password');
    await tester.tap(find.text('Sign in').last);
    await tester.pumpAndSettle();
    expect(find.text('Sign in to SkillTrack'), findsNothing);
    expect(find.text('No projects yet'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'creating a project opens its board and Back returns to dashboard',
    (tester) async {
      final projects = FakeProjectRepository();
      await showApp(tester, projects);
      await tester.tap(find.byKey(const Key('new-project-button')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('project-name-field')),
        'Flutter',
      );
      await tester.tap(find.byKey(const Key('save-project-button')));
      await tester.pumpAndSettle();
      expect(projects.stored.single.boardId, isNotNull);
      expect(find.text('Flutter'), findsOneWidget);
      expect(find.text('Kanban Board'), findsOneWidget);
      expect(find.byKey(const Key('new-task-button')), findsOneWidget);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.text('My Projects'), findsOneWidget);
      expect(find.text('Flutter'), findsOneWidget);
    },
  );

  testWidgets('selected project loads only tasks from its board', (
    tester,
  ) async {
    final projects = FakeProjectRepository(
      items: [
        sampleProject('1', 'Flutter', boardId: 'board-one'),
        sampleProject('2', 'Python', boardId: 'board-two'),
      ],
    );
    final kanban = FakeKanbanRepository(
      tasksByBoard: {
        'board-one': [sampleTask('1', 'Flutter task', KanbanStatus.todo)],
        'board-two': [sampleTask('2', 'Python task', KanbanStatus.todo)],
      },
    );
    await showApp(tester, projects, kanban: kanban);
    await tester.tap(find.byKey(const Key('project-1')));
    await tester.pumpAndSettle();
    expect(find.text('Flutter task'), findsOneWidget);
    expect(find.text('Python task'), findsNothing);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('project-2')));
    await tester.pumpAndSettle();
    expect(find.text('Python task'), findsOneWidget);
    expect(find.text('Flutter task'), findsNothing);
  });

  testWidgets('project can be archived and deletion requires confirmation', (
    tester,
  ) async {
    final projects = FakeProjectRepository(
      items: [sampleProject('1', 'Flutter')],
    );
    await showApp(tester, projects);
    await tester.tap(find.byTooltip('Project actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Archive Project'));
    await tester.pumpAndSettle();
    expect(projects.stored.single.project.status, 'archived');
    await tester.drag(find.byType(ListView).first, const Offset(-300, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Archived'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Project actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete Project'));
    await tester.pumpAndSettle();
    expect(find.text('Delete project?'), findsOneWidget);
    expect(projects.deleteCalled, false);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(projects.stored.length, 1);
  });

  testWidgets('dashboard offers retry after a load error', (tester) async {
    final projects = FakeProjectRepository()..failLoad = true;
    await showApp(tester, projects);
    expect(find.text('Unable to load projects'), findsOneWidget);
    projects.failLoad = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('No projects yet'), findsOneWidget);
  });

  testWidgets('edit route resolves a project ID and returns to dashboard', (
    tester,
  ) async {
    await showApp(
      tester,
      FakeProjectRepository(items: [sampleProject('1', 'Flutter')]),
    );
    await tester.tap(find.byTooltip('Project actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit Project'));
    await tester.pumpAndSettle();
    expect(find.text('Edit Project'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('project-name-field')))
          .controller
          ?.text,
      'Flutter',
    );
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('My Projects'), findsOneWidget);
  });

  testWidgets('router rejects missing board and task identifiers', (
    tester,
  ) async {
    await showApp(tester, FakeProjectRepository());
    final context = tester.element(find.text('My Projects'));
    final board = Navigator.of(context).pushNamed<dynamic>(
      AppRoutes.kanbanBoard,
      arguments: const BoardRouteArgs(
        projectId: 'project-1',
        boardId: '',
        projectName: 'Flutter',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Board unavailable'), findsWidgets);
    await tester.tap(find.text('Return to Projects'));
    await tester.pumpAndSettle();
    await board;
    final details = Navigator.of(context).pushNamed<dynamic>(
      AppRoutes.taskDetails,
      arguments: const TaskDetailsRouteArgs(
        projectId: 'project-1',
        boardId: 'board-1',
        projectName: 'Flutter',
        taskId: '',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Page unavailable'), findsWidgets);
    await tester.tap(find.text('Return to Projects'));
    await tester.pumpAndSettle();
    await details;
  });
}
