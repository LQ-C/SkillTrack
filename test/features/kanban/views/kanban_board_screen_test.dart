import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skilltrack/app/app_theme.dart';
import 'package:skilltrack/app/router/app_router.dart';
import 'package:skilltrack/features/kanban/models/kanban_filter.dart';
import 'package:skilltrack/features/kanban/models/kanban_status.dart';
import 'package:skilltrack/features/kanban/models/task_tag.dart';
import 'package:skilltrack/features/kanban/viewmodels/kanban_view_model.dart';
import 'package:skilltrack/features/kanban/views/kanban_board_screen.dart';
import 'package:skilltrack/features/kanban/widgets/board_loading_view.dart';
import 'package:skilltrack/features/kanban/widgets/task_tag_chip.dart';

import '../fake_repository.dart';
import '../../projects/fake_project_repository.dart';

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

  testWidgets('board shows progress, fixed columns and project name', (
    tester,
  ) async {
    await showBoard(
      tester,
      FakeKanbanRepository(
        tasks: [
          sampleTask('1', 'Plan', KanbanStatus.todo),
          sampleTask('2', 'Done', KanbanStatus.completed),
        ],
      ),
    );
    expect(find.text('Kanban Board'), findsOneWidget);
    expect(find.text('Project Progress'), findsOneWidget);
    expect(find.text('1 of 2 tasks completed'), findsOneWidget);
    expect(find.text('To-Do'), findsWidgets);
    expect(find.byKey(const Key('new-task-button')), findsOneWidget);
    expect(find.text('Test Project'), findsOneWidget);
    await tester.drag(find.byType(PageView), const Offset(-300, 0));
    await tester.pumpAndSettle();
    expect(find.text('In Progress'), findsOneWidget);
    await tester.drag(find.byType(PageView), const Offset(-300, 0));
    await tester.pumpAndSettle();
    expect(find.text('Completed'), findsOneWidget);
  });

  testWidgets('form validates blank title and creates a task', (tester) async {
    await showBoard(tester, FakeKanbanRepository());
    await tester.tap(find.byKey(const Key('new-task-button')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('save-task-button')));
    await tester.tap(find.byKey(const Key('save-task-button')));
    await tester.pumpAndSettle();
    expect(find.text('Task title is required'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('task-title-field')),
      'Study Flutter',
    );
    tester.testTextInput.hide();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('save-task-button')));
    await tester.tap(find.byKey(const Key('save-task-button')));
    await tester.pumpAndSettle();
    expect(find.text('Study Flutter'), findsOneWidget);
  });

  testWidgets('task details and archive confirmation open', (tester) async {
    await showBoard(
      tester,
      FakeKanbanRepository(tasks: [sampleTask('1', 'Plan', KanbanStatus.todo)]),
    );
    await tester.tap(find.text('Plan'));
    await tester.pumpAndSettle();
    expect(find.text('Checklist (0/0)'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Task actions').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Archive'));
    await tester.pumpAndSettle();
    expect(find.text('Archive task?'), findsOneWidget);
  });

  testWidgets('filters can produce empty results', (tester) async {
    final model = await showBoard(
      tester,
      FakeKanbanRepository(tasks: [sampleTask('1', 'Plan', KanbanStatus.todo)]),
    );
    model.applyFilter(KanbanFilter(statuses: {KanbanStatus.completed}));
    await tester.pumpAndSettle();
    expect(find.text('No matching tasks'), findsOneWidget);
  });

  testWidgets('task form can create and select a custom tag', (tester) async {
    await showBoard(tester, FakeKanbanRepository());
    await tester.tap(find.byKey(const Key('new-task-button')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('+ New Tag'));
    await tester.tap(find.text('+ New Tag'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('tag-name-field')), 'Revision');
    await tester.tap(find.byKey(const Key('save-tag-button')));
    await tester.pumpAndSettle();
    expect(find.text('Revision'), findsOneWidget);
    expect(
      tester.widget<TaskTagChip>(find.byType(TaskTagChip).last).selected,
      true,
    );
  });

  testWidgets('task form and filter use the same colored tag chip', (
    tester,
  ) async {
    const tag = TaskTag(
      id: 'tag-1',
      ownerId: 'user-1',
      name: 'Urgent',
      colorHex: '#E53935',
    );
    final repository = FakeKanbanRepository(
      tasks: [
        sampleTask('1', 'Plan', KanbanStatus.todo, tags: [tag]),
      ],
    )..tags = [tag];
    await showBoard(tester, repository);
    await tester.tap(find.byKey(const Key('new-task-button')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TaskTagChip>(find.byType(TaskTagChip).first).tag.colorHex,
      '#E53935',
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Board menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Filter tasks'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TaskTagChip>(find.byType(TaskTagChip).last).tag.colorHex,
      '#E53935',
    );
  });

  testWidgets('editing a tag color updates an existing board card', (
    tester,
  ) async {
    const tag = TaskTag(
      id: 'tag-1',
      ownerId: 'user-1',
      name: 'Research',
      colorHex: '#00897B',
    );
    final repository = FakeKanbanRepository(
      tasks: [
        sampleTask('1', 'Plan', KanbanStatus.todo, tags: [tag]),
      ],
    )..tags = [tag];
    final model = await showBoard(tester, repository);
    await tester.tap(find.byTooltip('Board menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Manage tags'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Edit Research'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('tag-color-#E53935')));
    await tester.tap(find.byKey(const Key('tag-color-#E53935')));
    await tester.tap(find.byKey(const Key('save-tag-button')));
    await tester.pumpAndSettle();
    expect(
      model.tasks(KanbanStatus.todo).single.tags.single.colorHex,
      '#E53935',
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(
      tester.widget<TaskTagChip>(find.byType(TaskTagChip).first).tag.colorHex,
      '#E53935',
    );
  });

  testWidgets('task page changes status and expands checklist options', (
    tester,
  ) async {
    final model = await showBoard(tester, FakeKanbanRepository());
    await tester.tap(find.byKey(const Key('new-task-button')));
    await tester.pumpAndSettle();
    expect(find.text('Add New Task'), findsOneWidget);
    expect(find.text('No time'), findsOneWidget);
    expect(find.text('Add attachment'), findsOneWidget);
    await tester.tap(find.byKey(const Key('status-in_progress')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('More Options'));
    await tester.pumpAndSettle();
    expect(find.text('Priority'), findsOneWidget);
    expect(find.text('Checklist'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('checklist-item-input')),
      'Read chapter',
    );
    await tester.ensureVisible(find.byTooltip('Add Item'));
    await tester.tap(find.byTooltip('Add Item'));
    await tester.enterText(find.byKey(const Key('task-title-field')), 'Study');
    await tester.tap(find.byKey(const Key('save-task-button')));
    await tester.pumpAndSettle();
    expect(model.allTasks.single.status, KanbanStatus.inProgress);
  });

  testWidgets('move-to menu changes task status', (tester) async {
    final model = await showBoard(
      tester,
      FakeKanbanRepository(tasks: [sampleTask('1', 'Plan', KanbanStatus.todo)]),
    );
    await tester.tap(find.byTooltip('Task actions').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move to In Progress'));
    await tester.pumpAndSettle();
    expect(model.allTasks.single.status, KanbanStatus.inProgress);
  });

  testWidgets('long press moves a task through the right edge', (tester) async {
    final model = await showBoard(
      tester,
      FakeKanbanRepository(tasks: [sampleTask('1', 'Plan', KanbanStatus.todo)]),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('task-1')).first),
    );
    await tester.pump(const Duration(milliseconds: 650));
    await gesture.moveTo(const Offset(380, 340));
    await tester.pump(const Duration(milliseconds: 550));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('column-in_progress')), findsOneWidget);
    await gesture.moveTo(const Offset(190, 350));
    await tester.pump();
    expect(
      find.byKey(const Key('drop-placeholder-in_progress')),
      findsOneWidget,
    );
    await gesture.up();
    await tester.pump();
    expect(find.byKey(const Key('drag-settle-overlay')), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('drag-settle-overlay')), findsNothing);
    expect(model.allTasks.single.status, KanbanStatus.inProgress);
  });

  testWidgets('release outside a column leaves the task untouched', (
    tester,
  ) async {
    final repository = FakeKanbanRepository(
      tasks: [sampleTask('1', 'Plan', KanbanStatus.todo)],
    );
    final model = await showBoard(tester, repository);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('task-1')).first),
    );
    await tester.pump(const Duration(milliseconds: 650));
    await gesture.moveTo(const Offset(10, 50));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(find.byKey(const Key('drag-settle-overlay')), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('drag-settle-overlay')), findsNothing);
    expect(model.allTasks.single.status, KanbanStatus.todo);
    expect(model.allTasks.single.sortOrder, 0);
    expect(repository.moveCalls, 0);
    expect(repository.reorderCalls, 0);
  });

  testWidgets('drag starts with an origin placeholder and no repository call', (
    tester,
  ) async {
    final repository = FakeKanbanRepository(
      tasks: [sampleTask('1', 'Plan', KanbanStatus.todo)],
    );
    await showBoard(tester, repository);
    final pageController = tester
        .widget<PageView>(find.byType(PageView))
        .controller;
    final cardWidth = tester
        .getSize(find.byKey(const Key('task-1')).first)
        .width;
    final touchPoint = tester.getCenter(find.byKey(const Key('task-1')).first);
    final gesture = await tester.startGesture(touchPoint);
    await tester.pump(const Duration(milliseconds: 650));
    expect(find.byKey(const Key('drag-origin-1')), findsOneWidget);
    expect(
      tester
          .widget<AnimatedScale>(find.byKey(const Key('drag-overview-scale')))
          .scale,
      .9,
    );
    expect(
      tester.widget<PageView>(find.byType(PageView)).controller,
      same(pageController),
    );
    expect(find.byKey(const Key('drag-edge-right')), findsOneWidget);
    expect(find.byKey(const Key('drag-edge-left')), findsNothing);
    expect(
      tester.getSize(find.byKey(const Key('drag-feedback-1'))).width,
      closeTo(cardWidth, 8),
    );
    expect(
      (tester.getCenter(find.byKey(const Key('drag-feedback-1'))) - touchPoint)
          .distance,
      lessThan(12),
    );
    expect(repository.moveCalls, 0);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('drag-origin-1')), findsNothing);
    expect(
      tester
          .widget<AnimatedScale>(find.byKey(const Key('drag-overview-scale')))
          .scale,
      1,
    );
    expect(find.byKey(const Key('drag-edge-right')), findsNothing);
  });

  testWidgets('hovering a column shows a labeled destination and border', (
    tester,
  ) async {
    await showBoard(
      tester,
      FakeKanbanRepository(tasks: [sampleTask('1', 'Plan', KanbanStatus.todo)]),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('task-1')).first),
    );
    await tester.pump(const Duration(milliseconds: 650));
    await gesture.moveTo(const Offset(190, 350));
    await tester.pump(const Duration(milliseconds: 220));
    expect(find.text('Move to To-Do'), findsWidgets);
    final column = tester.widget<AnimatedContainer>(
      find.byKey(const Key('column-todo')),
    );
    final border = (column.decoration! as BoxDecoration).border! as Border;
    expect(border.top.width, 2);
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('leaving an edge cancels pending column movement', (
    tester,
  ) async {
    final repository = FakeKanbanRepository(
      tasks: [sampleTask('1', 'Plan', KanbanStatus.todo)],
    );
    await showBoard(tester, repository);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('task-1')).first),
    );
    await tester.pump(const Duration(milliseconds: 650));
    await gesture.moveTo(const Offset(380, 340));
    await tester.pump(const Duration(milliseconds: 200));
    await gesture.moveTo(const Offset(190, 340));
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.widget<PageView>(find.byType(PageView)).controller!.page, 0);
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 700));
    expect(repository.moveCalls, 0);
  });

  testWidgets('ending an edge hover restores normal board swiping', (
    tester,
  ) async {
    await showBoard(
      tester,
      FakeKanbanRepository(tasks: [sampleTask('1', 'Plan', KanbanStatus.todo)]),
    );
    final controller = tester
        .widget<PageView>(find.byType(PageView))
        .controller!;
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('task-1')).first),
    );
    await tester.pump(const Duration(milliseconds: 650));
    await gesture.moveTo(const Offset(380, 340));
    await tester.pump(const Duration(milliseconds: 200));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 600));
    expect(controller.page, 0);
    expect(find.byKey(const Key('drag-edge-right')), findsNothing);
    await tester.drag(find.byType(PageView), const Offset(-300, 0));
    await tester.pumpAndSettle();
    expect(controller.page, 1);
  });

  testWidgets('failed drag rolls back its status and progress', (tester) async {
    final repository = FakeKanbanRepository(
      tasks: [sampleTask('1', 'Plan', KanbanStatus.todo)],
    )..failMove = true;
    final model = await showBoard(tester, repository);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('task-1')).first),
    );
    await tester.pump(const Duration(milliseconds: 650));
    await gesture.moveTo(const Offset(380, 340));
    await tester.pump(const Duration(milliseconds: 550));
    await tester.pump(const Duration(milliseconds: 300));
    await gesture.moveTo(const Offset(190, 350));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(model.allTasks.single.status, KanbanStatus.todo);
    expect(model.projectProgress, 0);
    expect(
      find.text('Unable to move the task. Please try again.'),
      findsOneWidget,
    );
  });

  testWidgets('one drag crosses two columns while held at the right edge', (
    tester,
  ) async {
    final model = await showBoard(
      tester,
      FakeKanbanRepository(tasks: [sampleTask('1', 'Plan', KanbanStatus.todo)]),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('task-1')).first),
    );
    await tester.pump(const Duration(milliseconds: 650));
    await gesture.moveTo(const Offset(380, 340));
    await tester.pump(const Duration(milliseconds: 550));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 550));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('column-completed')), findsOneWidget);
    expect(find.byKey(const Key('drag-edge-right')), findsNothing);
    expect(find.byKey(const Key('drag-edge-left')), findsOneWidget);
    expect(find.byKey(const Key('drag-feedback-1')), findsOneWidget);
    await gesture.moveTo(const Offset(190, 350));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(model.allTasks.single.status, KanbanStatus.completed);
    expect(model.allTasks.single.completedAt, isNotNull);
    expect(model.projectProgress, 1);
  });

  testWidgets('dragging left from Completed reaches To-Do', (tester) async {
    final model = await showBoard(
      tester,
      FakeKanbanRepository(
        tasks: [sampleTask('1', 'Plan', KanbanStatus.completed)],
      ),
    );
    await tester.drag(find.byType(PageView), const Offset(-300, 0));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(PageView), const Offset(-300, 0));
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('task-1')).first),
    );
    await tester.pump(const Duration(milliseconds: 650));
    expect(find.byKey(const Key('drag-edge-left')), findsOneWidget);
    expect(find.byKey(const Key('drag-edge-right')), findsNothing);
    await gesture.moveTo(const Offset(10, 340));
    await tester.pump(const Duration(milliseconds: 550));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 550));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('column-todo')), findsOneWidget);
    expect(find.byKey(const Key('drag-edge-left')), findsNothing);
    await gesture.moveTo(const Offset(190, 350));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(model.allTasks.single.status, KanbanStatus.todo);
    expect(model.allTasks.single.completedAt, isNull);
  });

  testWidgets('dragging within a column persists the placeholder order', (
    tester,
  ) async {
    final model = await showBoard(
      tester,
      FakeKanbanRepository(
        tasks: [
          sampleTask('1', 'First', KanbanStatus.todo),
          sampleTask('2', 'Second', KanbanStatus.todo).copyWith(sortOrder: 1),
        ],
      ),
    );
    final originalElement = tester.element(
      find.byKey(const Key('task-1')).first,
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('task-1')).first),
    );
    await tester.pump(const Duration(milliseconds: 650));
    final second = find.byKey(const Key('task-2')).first;
    await gesture.moveTo(tester.getCenter(second) + const Offset(0, 40));
    await tester.pump();
    expect(find.byKey(const Key('drop-placeholder-todo')), findsOneWidget);
    await gesture.up();
    await tester.pumpAndSettle();
    final ordered = model.tasks(KanbanStatus.todo);
    expect(ordered.map((task) => task.id), ['2', '1']);
    expect(ordered.map((task) => task.sortOrder), [0, 1]);
    expect(
      tester.element(find.byKey(const Key('task-1')).first),
      same(originalElement),
    );
  });

  testWidgets('board archive confirms and can be restored', (tester) async {
    await showBoard(
      tester,
      FakeKanbanRepository(tasks: [sampleTask('1', 'Plan', KanbanStatus.todo)]),
    );
    await tester.tap(find.byTooltip('Board menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Archive board'));
    await tester.pumpAndSettle();
    expect(find.text('Archive board?'), findsOneWidget);
    await tester.tap(find.text('Archive').last);
    await tester.pumpAndSettle();
    expect(find.text('Restore board'), findsOneWidget);
    await tester.tap(find.text('Restore board'));
    await tester.pumpAndSettle();
    expect(find.text('Plan'), findsOneWidget);
  });

  testWidgets('archiving a task collapses its card before removal', (
    tester,
  ) async {
    final repository = FakeKanbanRepository(
      tasks: [sampleTask('1', 'Plan', KanbanStatus.todo)],
    );
    await showBoard(tester, repository);
    await tester.tap(find.byTooltip('Task actions').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Archive'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Archive').last);
    await tester.pump();
    expect(repository.stored.single.isArchived, true);
    expect(find.byKey(const Key('task-1')), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const Key('task-1')), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('task-1')), findsNothing);
  });

  testWidgets('loading skeleton renders', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: BoardLoadingView())),
    );
    expect(find.bySemanticsLabel('Loading your board'), findsOneWidget);
  });

  testWidgets('error and empty board render', (tester) async {
    await showBoard(tester, FakeKanbanRepository(failLoad: true));
    expect(find.text('Unable to load the board'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await showBoard(tester, FakeKanbanRepository());
    expect(find.byKey(const Key('column-todo')), findsOneWidget);
    expect(find.text('No to-do tasks'), findsOneWidget);
    expect(find.text('No tasks yet'), findsNothing);
  });

  testWidgets('compact phone does not overflow', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        onGenerateRoute: AppRouter(
          projectRepository: FakeProjectRepository(),
          kanbanRepository: FakeKanbanRepository(),
        ).onGenerateRoute,
        home: KanbanBoardScreen(
          projectId: 'project-1',
          boardId: 'board-1',
          projectName: 'Test Project',
          viewModel: KanbanViewModel(
            FakeKanbanRepository(
              tasks: [
                sampleTask(
                  '1',
                  'A long task title for a compact phone',
                  KanbanStatus.todo,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion removes column and placeholder transitions', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = FakeKanbanRepository(
      tasks: [sampleTask('1', 'Plan', KanbanStatus.todo)],
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: KanbanBoardScreen(
            viewModel: KanbanViewModel(repository),
            projectId: 'project-1',
            boardId: 'board-1',
            projectName: 'Test Project',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final column = tester.widget<AnimatedContainer>(
      find.byKey(const Key('column-todo')),
    );
    expect(column.duration, Duration.zero);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('task-1')).first),
    );
    await tester.pump(const Duration(milliseconds: 650));
    expect(
      tester
          .widget<AnimatedScale>(find.byKey(const Key('drag-overview-scale')))
          .scale,
      1,
    );
    expect(find.byKey(const Key('drag-edge-right')), findsOneWidget);
    await gesture.moveTo(const Offset(10, 50));
    await gesture.up();
    await tester.pump();
    expect(find.byKey(const Key('drag-settle-overlay')), findsNothing);
  });

  testWidgets('a long column keeps drag interactions responsive', (
    tester,
  ) async {
    final repository = FakeKanbanRepository(
      tasks: [
        for (var i = 0; i < 50; i++)
          sampleTask('$i', 'Task $i', KanbanStatus.todo).copyWith(sortOrder: i),
      ],
    );
    await showBoard(tester, repository);
    expect(tester.takeException(), isNull);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('task-0')).first),
    );
    await tester.pump(const Duration(milliseconds: 650));
    await gesture.moveTo(const Offset(380, 340));
    await tester.pump(const Duration(milliseconds: 550));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('column-in_progress')), findsOneWidget);
    await gesture.moveTo(const Offset(190, 350));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(repository.moveCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('vertical drag scroll stops after leaving the edge', (
    tester,
  ) async {
    await showBoard(
      tester,
      FakeKanbanRepository(
        tasks: [
          for (var i = 0; i < 50; i++)
            sampleTask(
              '$i',
              'Task $i',
              KanbanStatus.todo,
            ).copyWith(sortOrder: i),
        ],
      ),
    );
    final listFinder = find
        .descendant(
          of: find.byKey(const Key('column-todo')),
          matching: find.byType(ListView),
        )
        .first;
    final controller = tester.widget<ListView>(listFinder).controller!;
    final rect = tester.getRect(listFinder);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('task-0')).first),
    );
    await tester.pump(const Duration(milliseconds: 650));
    await gesture.moveTo(Offset(rect.center.dx, rect.bottom - 12));
    await tester.pump(const Duration(milliseconds: 240));
    expect(controller.offset, greaterThan(0));
    await gesture.moveTo(rect.center);
    await tester.pump(const Duration(milliseconds: 40));
    final stoppedAt = controller.offset;
    await tester.pump(const Duration(milliseconds: 240));
    expect(controller.offset, stoppedAt);
    await gesture.moveTo(const Offset(10, 50));
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('drag remains active after its source scrolls offscreen', (
    tester,
  ) async {
    final model = await showBoard(
      tester,
      FakeKanbanRepository(
        tasks: [
          for (var i = 0; i < 50; i++)
            sampleTask(
              '$i',
              'Task $i',
              KanbanStatus.todo,
            ).copyWith(sortOrder: i),
        ],
      ),
    );
    final listFinder = find
        .descendant(
          of: find.byKey(const Key('column-todo')),
          matching: find.byType(ListView),
        )
        .first;
    final listRect = tester.getRect(listFinder);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('task-0')).first),
    );
    await tester.pump(const Duration(milliseconds: 650));
    await gesture.moveTo(Offset(listRect.center.dx, listRect.bottom - 8));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
    expect(
      tester.widget<ListView>(listFinder).controller!.offset,
      greaterThan(200),
    );
    await gesture.moveTo(const Offset(380, 340));
    await tester.pump(const Duration(milliseconds: 550));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('column-in_progress')), findsOneWidget);
    await gesture.moveTo(const Offset(190, 350));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(
      model.allTasks.where((task) => task.id == '0').single.status,
      KanbanStatus.inProgress,
    );
  });

  testWidgets('task page keeps its action visible on a compact phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        onGenerateRoute: AppRouter(
          projectRepository: FakeProjectRepository(),
          kanbanRepository: FakeKanbanRepository(),
        ).onGenerateRoute,
        home: KanbanBoardScreen(
          projectId: 'project-1',
          boardId: 'board-1',
          projectName: 'Test Project',
          viewModel: KanbanViewModel(FakeKanbanRepository()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('new-task-button')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('More Options'));
    await tester.tap(find.text('More Options'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('task-title-field')), 'Study');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('save-task-button')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
