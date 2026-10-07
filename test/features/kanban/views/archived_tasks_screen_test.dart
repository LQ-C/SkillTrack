import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skilltrack/app/app_theme.dart';
import 'package:skilltrack/app/router/app_router.dart';
import 'package:skilltrack/features/kanban/models/kanban_status.dart';
import 'package:skilltrack/features/kanban/models/task_tag.dart';
import 'package:skilltrack/features/kanban/viewmodels/kanban_view_model.dart';
import 'package:skilltrack/features/kanban/views/kanban_board_screen.dart';
import 'package:skilltrack/features/kanban/widgets/task_tag_chip.dart';

import '../../projects/fake_project_repository.dart';
import '../fake_repository.dart';

void main() {
  Future<KanbanViewModel> showBoard(
    WidgetTester tester,
    FakeKanbanRepository repository,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final model = KanbanViewModel(repository);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        onGenerateRoute: AppRouter(
          projectRepository: FakeProjectRepository(),
          kanbanRepository: repository,
        ).onGenerateRoute,
        home: KanbanBoardScreen(
          viewModel: model,
          projectId: 'project-1',
          boardId: 'board-1',
          projectName: 'Test Project',
        ),
      ),
    );
    await tester.pumpAndSettle();
    return model;
  }

  Future<void> openArchive(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Board menu'));
    await tester.pumpAndSettle();
    expect(find.text('Archived Tasks'), findsOneWidget);
    await tester.tap(find.text('Archived Tasks'));
    await tester.pumpAndSettle();
  }

  testWidgets('board menu opens board-scoped archived tasks and returns', (
    tester,
  ) async {
    await showBoard(
      tester,
      FakeKanbanRepository(
        tasks: [
          sampleTask(
            '1',
            'Archived here',
            KanbanStatus.todo,
          ).copyWith(isArchived: true),
          sampleTask('2', 'Active here', KanbanStatus.todo),
          sampleTask(
            '3',
            'Other board',
            KanbanStatus.todo,
          ).copyWith(boardId: 'board-2', isArchived: true),
        ],
      ),
    );
    expect(find.text('Archived here'), findsNothing);
    await openArchive(tester);
    expect(find.text('Archived Tasks'), findsOneWidget);
    expect(find.byKey(const Key('archived-task-1')), findsOneWidget);
    expect(find.text('Active here'), findsNothing);
    expect(find.text('Other board'), findsNothing);
    await tester.tap(find.byTooltip('Back to Board'));
    await tester.pumpAndSettle();
    expect(find.text('Kanban Board'), findsOneWidget);
  });

  testWidgets('archived cards retain their assigned tag colors', (
    tester,
  ) async {
    const tag = TaskTag(
      id: 'tag-1',
      ownerId: 'user-1',
      name: 'Research',
      colorHex: '#00897B',
    );
    await showBoard(
      tester,
      FakeKanbanRepository(
        tasks: [
          sampleTask(
            '1',
            'Archived work',
            KanbanStatus.todo,
            tags: [tag],
          ).copyWith(isArchived: true),
        ],
      )..tags = [tag],
    );
    await openArchive(tester);
    final chip = tester.widget<TaskTagChip>(find.byType(TaskTagChip).first);
    expect(chip.tag.name, 'Research');
    expect(chip.tag.colorHex, '#00897B');
    await tester.tap(find.byTooltip('Archived task actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restore task'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restore'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Return to Board'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TaskTagChip>(find.byType(TaskTagChip).first).tag.colorHex,
      '#00897B',
    );
  });

  testWidgets('restore confirms, empties archive and refreshes active board', (
    tester,
  ) async {
    final model = await showBoard(
      tester,
      FakeKanbanRepository(
        tasks: [
          sampleTask('1', 'Plan', KanbanStatus.todo).copyWith(isArchived: true),
        ],
      ),
    );
    expect(model.totalTaskCount, 0);
    await openArchive(tester);
    await tester.tap(find.byTooltip('Archived task actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restore task'));
    await tester.pumpAndSettle();
    expect(find.text('Restore task?'), findsOneWidget);
    expect(
      find.text('This task will return to the Kanban Board.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('archived-task-1')), findsOneWidget);
    await tester.tap(find.byTooltip('Archived task actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restore task'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restore'));
    await tester.pumpAndSettle();
    expect(find.text('No archived tasks'), findsOneWidget);
    await tester.tap(find.text('Return to Board'));
    await tester.pumpAndSettle();
    expect(find.text('Plan'), findsOneWidget);
    expect(model.totalTaskCount, 1);
    expect(model.tasks(KanbanStatus.todo).single.id, '1');
  });

  testWidgets('restored completed task updates board progress and count', (
    tester,
  ) async {
    final model = await showBoard(
      tester,
      FakeKanbanRepository(
        tasks: [
          sampleTask(
            '1',
            'Finished',
            KanbanStatus.completed,
          ).copyWith(isArchived: true),
        ],
      ),
    );
    expect(model.projectProgress, 0);
    await openArchive(tester);
    await tester.tap(find.byTooltip('Archived task actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restore task'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restore'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Return to Board'));
    await tester.pumpAndSettle();
    expect(model.completedTaskCount, 1);
    expect(model.tasks(KanbanStatus.completed).length, 1);
    expect(model.projectProgress, 1);
  });

  testWidgets('search empty and read-only details work', (tester) async {
    await showBoard(
      tester,
      FakeKanbanRepository(
        tasks: [
          sampleTask(
            '1',
            'Archived plan',
            KanbanStatus.inProgress,
          ).copyWith(isArchived: true),
        ],
      ),
    );
    await openArchive(tester);
    await tester.tap(find.byTooltip('Search archived tasks'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('archived-search')), 'missing');
    await tester.pumpAndSettle();
    expect(find.text('No matching archived tasks'), findsOneWidget);
    await tester.tap(find.text('Clear search'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('archived-task-1')));
    await tester.pumpAndSettle();
    expect(find.text('In Progress'), findsWidgets);
    expect(find.text('Archived'), findsWidgets);
  });

  testWidgets('restore all and permanent delete require confirmation', (
    tester,
  ) async {
    final repository = FakeKanbanRepository(
      tasks: [
        sampleTask('1', 'First', KanbanStatus.todo).copyWith(isArchived: true),
        sampleTask(
          '2',
          'Second',
          KanbanStatus.completed,
        ).copyWith(isArchived: true),
      ],
    );
    await showBoard(tester, repository);
    await openArchive(tester);
    await tester.tap(find.byTooltip('Archived task actions').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete permanently'));
    await tester.pumpAndSettle();
    expect(find.text('Delete task permanently?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(repository.stored.length, 2);
    await tester.tap(find.byTooltip('Archived tasks menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restore all'));
    await tester.pumpAndSettle();
    expect(find.text('Restore all tasks?'), findsOneWidget);
    await tester.tap(find.text('Restore All'));
    await tester.pumpAndSettle();
    expect(find.text('No archived tasks'), findsOneWidget);
    expect(repository.stored.every((task) => !task.isArchived), true);
  });

  testWidgets('confirmed permanent delete removes the archived card', (
    tester,
  ) async {
    final repository = FakeKanbanRepository(
      tasks: [
        sampleTask(
          '1',
          'Old task',
          KanbanStatus.todo,
        ).copyWith(isArchived: true),
      ],
    );
    await showBoard(tester, repository);
    await openArchive(tester);
    await tester.tap(find.byTooltip('Archived task actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete permanently'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete Permanently'));
    await tester.pump();
    expect(repository.stored, isEmpty);
    expect(find.byKey(const Key('archived-task-1')), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const Key('archived-task-1')), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('No archived tasks'), findsOneWidget);
    expect(repository.stored, isEmpty);
  });

  testWidgets('load error shows retry and recovers', (tester) async {
    final repository = FakeKanbanRepository(failLoad: true);
    await showBoard(tester, repository);
    await openArchive(tester);
    expect(find.text('Unable to load archived tasks'), findsOneWidget);
    repository.failLoad = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('No archived tasks'), findsOneWidget);
  });

  testWidgets('archived list supports compact screens and larger text', (
    tester,
  ) async {
    await showBoard(
      tester,
      FakeKanbanRepository(
        tasks: [
          sampleTask(
            '1',
            'A long archived learning task',
            KanbanStatus.todo,
          ).copyWith(isArchived: true),
        ],
      ),
    );
    tester.view.physicalSize = const Size(320, 640);
    tester.binding.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(
      tester.binding.platformDispatcher.clearTextScaleFactorTestValue,
    );
    await tester.pumpAndSettle();
    await openArchive(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('missing board argument uses router fallback', (tester) async {
    final repository = FakeKanbanRepository();
    await tester.pumpWidget(
      MaterialApp(
        onGenerateRoute: AppRouter(
          projectRepository: FakeProjectRepository(),
          kanbanRepository: repository,
        ).onGenerateRoute,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => AppRouter.archivedTasks(
                context,
                const BoardRouteArgs(
                  projectId: 'project-1',
                  boardId: '',
                  projectName: 'Project',
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Board unavailable'), findsWidgets);
  });
}
