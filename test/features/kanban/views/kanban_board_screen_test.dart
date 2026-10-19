import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skilltrack/app/app_theme.dart';
import 'package:skilltrack/app/router/app_router.dart';
import 'package:skilltrack/features/kanban/models/kanban_filter.dart';
import 'package:skilltrack/features/kanban/models/kanban_sort.dart';
import 'package:skilltrack/features/kanban/models/kanban_status.dart';
import 'package:skilltrack/features/kanban/models/task_tag.dart';
import 'package:skilltrack/features/kanban/viewmodels/kanban_view_model.dart';
import 'package:skilltrack/features/kanban/views/kanban_board_screen.dart';
import 'package:skilltrack/features/kanban/widgets/board_loading_view.dart';
import 'package:skilltrack/features/kanban/widgets/kanban_status_column.dart';
import 'package:skilltrack/features/kanban/widgets/task_tag_chip.dart';

import '../fake_repository.dart';
import '../../projects/fake_project_repository.dart';

void main() {
  Future<KanbanViewModel> showBoard(
    WidgetTester tester,
    FakeKanbanRepository repository, {
    Size size = const Size(390, 844),
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
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
        home: MediaQuery(
          data: MediaQueryData.fromView(
            tester.view,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: KanbanBoardScreen(
            viewModel: model,
            projectId: 'project-1',
            boardId: 'board-1',
            projectName: 'Test Project',
          ),
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
    await tester.drag(
      find.byKey(const Key('board-swipe-area')),
      const Offset(-300, 0),
    );
    await tester.pumpAndSettle();
    expect(find.text('In Progress'), findsOneWidget);
    await tester.drag(
      find.byKey(const Key('board-swipe-area')),
      const Offset(-300, 0),
    );
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

  testWidgets('destination placeholder follows rendered card midpoints', (
    tester,
  ) async {
    const tag = TaskTag(
      id: 'tag-1',
      ownerId: 'user-1',
      name: 'Longer card',
      colorHex: '#5C6BC0',
    );
    final repository = FakeKanbanRepository(
      tasks: [
        sampleTask('b', 'Task B', KanbanStatus.todo, order: 1000),
        sampleTask('d', 'Task D', KanbanStatus.inProgress, order: 1000),
        sampleTask(
          'e',
          'Task E',
          KanbanStatus.inProgress,
          order: 2000,
          tags: [tag],
        ),
        sampleTask('f', 'Task F', KanbanStatus.inProgress, order: 3000),
      ],
    );
    final model = await showBoard(
      tester,
      repository,
      size: const Size(390, 1100),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('task-b')).first),
    );
    await tester.pump(const Duration(milliseconds: 650));
    await gesture.moveTo(const Offset(380, 340));
    await tester.pump(const Duration(milliseconds: 550));
    await tester.pump(const Duration(milliseconds: 300));
    final first = tester.getRect(find.byKey(const Key('task-d')).first);
    final second = tester.getRect(find.byKey(const Key('task-e')).first);
    expect(first.height, isNot(second.height));

    await gesture.moveTo(Offset(190, first.top + 8));
    await tester.pump(const Duration(milliseconds: 220));
    var placeholder = tester.getRect(
      find.byKey(const Key('drop-placeholder-in_progress')),
    );
    expect(
      placeholder.top,
      lessThan(tester.getRect(find.byKey(const Key('task-d')).first).top),
    );
    expect(repository.moveCalls, 0);
    expect(repository.reorderCalls, 0);
    expect(repository.activityEvents, isEmpty);

    final secondNow = tester.getRect(find.byKey(const Key('task-e')).first);
    await gesture.moveTo(Offset(190, secondNow.top + 8));
    await tester.pump(const Duration(milliseconds: 220));
    await tester.pump(const Duration(milliseconds: 220));
    final slot = tester.widget<AnimatedSize>(
      find.byKey(const ValueKey('slot-in_progress-1')),
    );
    expect(slot.duration, const Duration(milliseconds: 200));
    expect(
      tester.getRect(find.byKey(const ValueKey('slot-in_progress-1'))).height,
      closeTo(tester.getRect(find.byKey(const Key('task-b')).first).height, 5),
    );
    placeholder = tester.getRect(
      find.byKey(const Key('drop-placeholder-in_progress')),
    );
    expect(
      placeholder.top,
      greaterThan(tester.getRect(find.byKey(const Key('task-d')).first).top),
    );
    expect(
      placeholder.bottom,
      lessThan(tester.getRect(find.byKey(const Key('task-e')).first).bottom),
    );

    final secondMidpoint = tester
        .getRect(find.byKey(const Key('task-e')).first)
        .center
        .dy;
    await gesture.moveTo(Offset(190, secondMidpoint + 5));
    await tester.pump(const Duration(milliseconds: 220));
    placeholder = tester.getRect(
      find.byKey(const Key('drop-placeholder-in_progress')),
    );
    expect(
      placeholder.top,
      greaterThan(tester.getRect(find.byKey(const Key('task-e')).first).top),
    );

    final lastMidpoint = tester
        .getRect(find.byKey(const Key('task-f')).first)
        .center
        .dy;
    await gesture.moveTo(Offset(190, lastMidpoint + 5));
    await tester.pump(const Duration(milliseconds: 220));
    placeholder = tester.getRect(
      find.byKey(const Key('drop-placeholder-in_progress')),
    );
    expect(
      placeholder.top,
      greaterThan(tester.getRect(find.byKey(const Key('task-f')).first).top),
    );
    final secondBeforeDrop = tester.getRect(
      find.byKey(const Key('task-e')).first,
    );
    await gesture.moveTo(Offset(190, secondBeforeDrop.top + 8));
    await tester.pump(const Duration(milliseconds: 220));

    await gesture.up();
    await tester.pumpAndSettle();
    expect(model.tasks(KanbanStatus.inProgress).map((task) => task.id), [
      'd',
      'b',
      'e',
      'f',
    ]);
    expect(model.tasks(KanbanStatus.todo), isEmpty);
    expect(repository.activityEvents, hasLength(1));
    expect(repository.activityEvents.single.newValues['position'], 1);
  });

  testWidgets('empty destination centers a drop placeholder', (tester) async {
    final repository = FakeKanbanRepository(
      tasks: [sampleTask('b', 'Task B', KanbanStatus.todo, order: 1000)],
    );
    final model = await showBoard(tester, repository);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('task-b')).first),
    );
    await tester.pump(const Duration(milliseconds: 650));
    await gesture.moveTo(const Offset(380, 340));
    await tester.pump(const Duration(milliseconds: 550));
    await tester.pump(const Duration(milliseconds: 300));
    await gesture.moveTo(const Offset(190, 450));
    await tester.pump(const Duration(milliseconds: 220));
    final list = tester.getRect(
      find
          .descendant(
            of: find.byKey(const Key('column-in_progress')),
            matching: find.byType(ListView),
          )
          .first,
    );
    final placeholder = tester.getRect(
      find.byKey(const Key('drop-placeholder-in_progress')),
    );
    expect(find.text('Drop task here'), findsOneWidget);
    expect(placeholder.center.dy, closeTo(list.center.dy, 50));
    expect(repository.moveCalls, 0);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(model.tasks(KanbanStatus.inProgress).single.sortOrder, 1000);
  });

  testWidgets('cross-status cancellation preserves source order and counts', (
    tester,
  ) async {
    final repository = FakeKanbanRepository(
      tasks: [
        sampleTask('b', 'Task B', KanbanStatus.todo, order: 1000),
        sampleTask('d', 'Task D', KanbanStatus.inProgress, order: 1000),
      ],
    );
    final model = await showBoard(tester, repository);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('task-b')).first),
    );
    await tester.pump(const Duration(milliseconds: 650));
    await gesture.moveTo(const Offset(380, 340));
    await tester.pump(const Duration(milliseconds: 550));
    await tester.pump(const Duration(milliseconds: 300));
    await gesture.moveTo(const Offset(190, 350));
    await tester.pump(const Duration(milliseconds: 220));
    expect(
      find.byKey(const Key('drop-placeholder-in_progress')),
      findsOneWidget,
    );
    await gesture.moveTo(const Offset(10, 50));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(model.tasks(KanbanStatus.todo).single.sortOrder, 1000);
    expect(model.tasks(KanbanStatus.inProgress).single.id, 'd');
    expect(model.projectProgress, 0);
    expect(repository.moveCalls, 0);
    expect(repository.reorderCalls, 0);
    expect(repository.activityEvents, isEmpty);
  });

  testWidgets('destination auto-scroll advances the insertion position', (
    tester,
  ) async {
    final repository = FakeKanbanRepository(
      tasks: [
        sampleTask('b', 'Task B', KanbanStatus.todo, order: 1000),
        for (var i = 0; i < 35; i++)
          sampleTask(
            'd$i',
            'Task $i',
            KanbanStatus.inProgress,
            order: (i + 1) * 1000,
          ),
      ],
    );
    final model = await showBoard(tester, repository);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('task-b')).first),
    );
    await tester.pump(const Duration(milliseconds: 650));
    await gesture.moveTo(const Offset(380, 340));
    await tester.pump(const Duration(milliseconds: 550));
    await tester.pump(const Duration(milliseconds: 300));
    final listFinder = find
        .descendant(
          of: find.byKey(const Key('column-in_progress')),
          matching: find.byType(ListView),
        )
        .first;
    final list = tester.getRect(listFinder);
    final controller = tester.widget<ListView>(listFinder).controller!;
    await gesture.moveTo(Offset(list.center.dx, list.bottom - 8));
    for (var i = 0; i < 24; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
    expect(controller.offset, greaterThan(200));
    expect(
      find.byKey(const Key('drop-placeholder-in_progress')),
      findsOneWidget,
    );
    expect(repository.moveCalls, 0);
    expect(repository.reorderCalls, 0);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(model.tasks(KanbanStatus.inProgress), hasLength(36));
    expect(repository.activityEvents, hasLength(1));
    expect(
      repository.activityEvents.single.newValues['position'],
      greaterThan(3),
    );
  });

  testWidgets('drag starts with an origin placeholder and no repository call', (
    tester,
  ) async {
    final repository = FakeKanbanRepository(
      tasks: [sampleTask('1', 'Plan', KanbanStatus.todo)],
    );
    await showBoard(tester, repository);
    final track = tester.element(find.byKey(const Key('kanban-board-track')));
    final cardWidth = tester
        .getSize(find.byKey(const Key('task-1')).first)
        .width;
    final touchPoint = tester.getCenter(find.byKey(const Key('task-1')).first);
    final gesture = await tester.startGesture(touchPoint);
    await tester.pump(const Duration(milliseconds: 650));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('drag-origin-1')), findsOneWidget);
    expect(
      tester
          .widget<Transform>(find.byKey(const Key('drag-overview-scale')))
          .transform
          .entry(0, 0),
      .9,
    );
    expect(
      tester.element(find.byKey(const Key('kanban-board-track'))),
      same(track),
    );
    expect(find.byKey(const Key('drag-edge-right')), findsOneWidget);
    expect(find.byKey(const Key('drag-edge-left')), findsOneWidget);
    final feedback = tester.getRect(find.byKey(const Key('drag-feedback-1')));
    expect(feedback.width, lessThan(cardWidth));
    expect(feedback.contains(touchPoint), isTrue);
    expect(repository.moveCalls, 0);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('drag-origin-1')), findsNothing);
    expect(
      tester
          .widget<Transform>(find.byKey(const Key('drag-overview-scale')))
          .transform
          .entry(0, 0),
      1,
    );
    expect(find.byKey(const Key('drag-edge-right')), findsNothing);
  });

  testWidgets('one scaled track exposes real neighboring columns', (
    tester,
  ) async {
    await showBoard(
      tester,
      FakeKanbanRepository(
        tasks: [
          sampleTask('1', 'Previous task', KanbanStatus.todo),
          sampleTask('2', 'Drag me', KanbanStatus.inProgress),
          sampleTask('3', 'Next task', KanbanStatus.completed),
        ],
      ),
    );
    await tester.drag(
      find.byKey(const Key('board-swipe-area')),
      const Offset(-300, 0),
    );
    await tester.pumpAndSettle();
    final normalGap = tester
        .getRect(find.byKey(const Key('column-gap-0')))
        .width;
    expect(normalGap, closeTo(12, .01));
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('task-2')).first),
    );
    await tester.pump(const Duration(milliseconds: 650));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(KanbanStatusColumn), findsNWidgets(3));
    expect(find.byKey(const Key('drag-side-left')), findsNothing);
    expect(find.byKey(const Key('drag-side-right')), findsNothing);
    final left = tester.getRect(find.byKey(const Key('column-todo')));
    final center = tester.getRect(find.byKey(const Key('column-in_progress')));
    final right = tester.getRect(find.byKey(const Key('column-completed')));
    final firstGap = tester.getRect(find.byKey(const Key('column-gap-0')));
    final secondGap = tester.getRect(find.byKey(const Key('column-gap-1')));
    final viewport = tester.getRect(find.byKey(const Key('board-swipe-area')));
    expect(left.right, closeTo(firstGap.left, 1));
    expect(firstGap.right, closeTo(center.left, 1));
    expect(center.right, closeTo(secondGap.left, 1));
    expect(secondGap.right, closeTo(right.left, 1));
    expect(firstGap.width, closeTo(10.8, 1));
    expect(firstGap.width, closeTo(normalGap * .9, 1));
    expect(secondGap.width, closeTo(firstGap.width, .01));
    expect(center.top, closeTo(viewport.top, 1));
    expect(center.bottom, closeTo(viewport.bottom, 1));
    expect(center.center.dx, closeTo(195, 1));
    expect(left.right, greaterThanOrEqualTo(48));
    expect(390 - right.left, greaterThanOrEqualTo(48));
    final track = tester.widget<SizedBox>(
      find.byKey(const Key('kanban-board-track')),
    );
    expect(
      (track.child! as ColoredBox).color,
      AppTheme.light.scaffoldBackgroundColor,
    );
    for (final status in ['todo', 'in_progress', 'completed']) {
      final surface = tester.widget<AnimatedContainer>(
        find.byKey(Key('column-$status')),
      );
      final decoration = surface.decoration! as BoxDecoration;
      expect(decoration.color!.a, 1);
      expect(decoration.borderRadius, BorderRadius.circular(18));
    }
    expect(left.height, closeTo(center.height, 1));
    expect(center.height, closeTo(right.height, 1));
    final leftControl = find.byKey(const Key('drag-arrow-left'));
    final rightControl = find.byKey(const Key('drag-arrow-right'));
    expect(tester.getSize(leftControl), const Size(64, 72));
    expect(tester.getSize(rightControl), const Size(64, 72));
    final leftDecoration =
        tester
                .widget<AnimatedContainer>(
                  find.descendant(
                    of: leftControl,
                    matching: find.byType(AnimatedContainer),
                  ),
                )
                .decoration!
            as BoxDecoration;
    final rightDecoration =
        tester
                .widget<AnimatedContainer>(
                  find.descendant(
                    of: rightControl,
                    matching: find.byType(AnimatedContainer),
                  ),
                )
                .decoration!
            as BoxDecoration;
    expect(leftDecoration.borderRadius, rightDecoration.borderRadius);
    expect(
      tester.getRect(leftControl).left,
      closeTo(390 - tester.getRect(rightControl).right, 1),
    );
    final completedLabel = tester.widget<Text>(
      find.descendant(of: rightControl, matching: find.text('Completed')),
    );
    expect(completedLabel.maxLines, 1);
    expect(completedLabel.softWrap, false);
    final feedback = tester.getRect(find.byKey(const Key('drag-feedback-2')));
    expect(feedback.width, greaterThan(200));
    expect(feedback.left, greaterThanOrEqualTo(8));
    expect(feedback.right, lessThanOrEqualTo(382));
    final newTaskOpacity = tester.widget<AnimatedOpacity>(
      find
          .ancestor(
            of: find.byKey(const Key('new-task-button')),
            matching: find.byType(AnimatedOpacity),
          )
          .first,
    );
    expect(newTaskOpacity.opacity, 0);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('drag-edge-left')), findsNothing);
  });

  testWidgets('edge hover highlights the real adjacent column', (tester) async {
    await showBoard(
      tester,
      FakeKanbanRepository(tasks: [sampleTask('1', 'Plan', KanbanStatus.todo)]),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('task-1')).first),
    );
    await tester.pump(const Duration(milliseconds: 650));
    await tester.pump(const Duration(milliseconds: 300));
    final originalSize = tester.getSize(
      find.byKey(const Key('column-in_progress')),
    );
    await gesture.moveTo(const Offset(380, 340));
    await tester.pump(const Duration(milliseconds: 80));
    final surface = tester.widget<AnimatedContainer>(
      find.byKey(const Key('column-in_progress')),
    );
    final decoration = surface.decoration! as BoxDecoration;
    expect(decoration.color!.a, 1);
    expect((decoration.border! as Border).top.width, 1.5);
    expect(decoration.boxShadow, isNotEmpty);
    expect(
      tester.getSize(find.byKey(const Key('column-in_progress'))),
      originalSize,
    );
    await gesture.moveTo(const Offset(190, 340));
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      tester.getCenter(find.byKey(const Key('column-todo'))).dx,
      closeTo(195, 1),
    );
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('boundary control stays in place and is disabled', (
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
    expect(find.byKey(const Key('drag-arrow-left')), findsOneWidget);
    expect(find.byKey(const Key('drag-arrow-right')), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const Key('drag-arrow-left'))),
      tester.getSize(find.byKey(const Key('drag-arrow-right'))),
    );
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('shared track fits a narrow phone while dragging', (
    tester,
  ) async {
    await showBoard(
      tester,
      FakeKanbanRepository(
        tasks: [sampleTask('1', 'Plan', KanbanStatus.inProgress)],
      ),
    );
    tester.view.physicalSize = const Size(320, 700);
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const Key('board-swipe-area')),
      const Offset(-280, 0),
    );
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('task-1')).first),
    );
    await tester.pump(const Duration(milliseconds: 650));
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      tester.getCenter(find.byKey(const Key('column-in_progress'))).dx,
      closeTo(160, 1),
    );
    expect(tester.takeException(), isNull);
    await gesture.up();
    await tester.pumpAndSettle();
  });

  for (final (size, textScale) in [
    (const Size(320, 700), 1.0),
    (const Size(360, 780), 1.0),
    (const Size(390, 844), 1.0),
    (const Size(320, 700), 1.6),
  ]) {
    testWidgets('track and feedback fit $size at ${textScale}x text', (
      tester,
    ) async {
      await showBoard(
        tester,
        FakeKanbanRepository(
          tasks: [sampleTask('1', 'Plan', KanbanStatus.inProgress)],
        ),
        size: size,
        textScale: textScale,
      );
      await tester.drag(
        find.byKey(const Key('board-swipe-area')),
        const Offset(-280, 0),
      );
      await tester.pumpAndSettle();
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('task-1')).first),
      );
      await tester.pump(const Duration(milliseconds: 650));
      await tester.pump(const Duration(milliseconds: 300));
      final left = tester.getRect(find.byKey(const Key('column-todo')));
      final center = tester.getRect(
        find.byKey(const Key('column-in_progress')),
      );
      final right = tester.getRect(find.byKey(const Key('column-completed')));
      final viewport = tester.getRect(
        find.byKey(const Key('board-swipe-area')),
      );
      final feedback = tester.getRect(find.byKey(const Key('drag-feedback-1')));
      final firstGap = tester.getRect(find.byKey(const Key('column-gap-0')));
      final secondGap = tester.getRect(find.byKey(const Key('column-gap-1')));
      expect(left.right, closeTo(firstGap.left, 1));
      expect(firstGap.right, closeTo(center.left, 1));
      expect(center.right, closeTo(secondGap.left, 1));
      expect(secondGap.right, closeTo(right.left, 1));
      expect(firstGap.width, closeTo(secondGap.width, .01));
      expect(center.top, closeTo(viewport.top, 1));
      expect(center.bottom, closeTo(viewport.bottom, 1));
      expect(feedback.left, greaterThanOrEqualTo(8));
      expect(feedback.right, lessThanOrEqualTo(size.width - 8));
      expect(tester.takeException(), isNull);
      await gesture.up();
      await tester.pumpAndSettle();
    });
  }

  testWidgets('real neighboring column accepts a drop before status follow', (
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
    await tester.pump(const Duration(milliseconds: 300));
    await gesture.moveTo(const Offset(380, 340));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(model.allTasks.single.status, KanbanStatus.inProgress);
    expect(
      tester.getCenter(find.byKey(const Key('column-in_progress'))).dx,
      closeTo(195, 1),
    );
  });

  testWidgets('off-center long press keeps feedback inside the board', (
    tester,
  ) async {
    await showBoard(
      tester,
      FakeKanbanRepository(tasks: [sampleTask('1', 'Plan', KanbanStatus.todo)]),
    );
    final card = tester.getRect(find.byKey(const Key('task-1')).first);
    final gesture = await tester.startGesture(
      card.topLeft + const Offset(24, 24),
    );
    await tester.pump(const Duration(milliseconds: 650));
    await tester.pump(const Duration(milliseconds: 300));
    final feedback = tester.getRect(find.byKey(const Key('drag-feedback-1')));
    final board = tester.getRect(find.byKey(const Key('board-swipe-area')));
    expect(feedback.top, greaterThanOrEqualTo(board.top - 2));
    expect(feedback.left, greaterThanOrEqualTo(8));
    await gesture.moveTo(const Offset(10, 50));
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('columns stay mounted and keep their vertical scroll positions', (
    tester,
  ) async {
    await showBoard(
      tester,
      FakeKanbanRepository(
        tasks: [
          for (var i = 0; i < 40; i++)
            sampleTask(
              '$i',
              'Task $i',
              KanbanStatus.todo,
            ).copyWith(sortOrder: i),
        ],
      ),
    );
    final todoList = find.descendant(
      of: find.byKey(const Key('column-todo')),
      matching: find.byType(ListView),
    );
    final controller = tester.widget<ListView>(todoList).controller!;
    await tester.drag(todoList, const Offset(0, -420));
    await tester.pumpAndSettle();
    final savedOffset = controller.offset;
    expect(savedOffset, greaterThan(0));
    await tester.drag(
      find.byKey(const Key('board-swipe-area')),
      const Offset(-300, 0),
    );
    await tester.pumpAndSettle();
    expect(find.byType(KanbanStatusColumn), findsNWidgets(3));
    await tester.drag(
      find.byKey(const Key('board-swipe-area')),
      const Offset(300, 0),
    );
    await tester.pumpAndSettle();
    expect(controller.offset, closeTo(savedOffset, 1));
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
    expect(border.top.width, 1.5);
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
    expect(
      tester.getCenter(find.byKey(const Key('column-todo'))).dx,
      closeTo(195, 1),
    );
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
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('task-1')).first),
    );
    await tester.pump(const Duration(milliseconds: 650));
    await gesture.moveTo(const Offset(380, 340));
    await tester.pump(const Duration(milliseconds: 200));
    await gesture.moveTo(const Offset(10, 50));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 600));
    expect(
      tester.getCenter(find.byKey(const Key('column-todo'))).dx,
      closeTo(195, 1),
    );
    expect(find.byKey(const Key('drag-edge-right')), findsNothing);
    await tester.drag(
      find.byKey(const Key('board-swipe-area')),
      const Offset(-300, 0),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getCenter(find.byKey(const Key('column-in_progress'))).dx,
      closeTo(195, 1),
    );
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
    expect(find.byKey(const Key('drag-edge-right')), findsOneWidget);
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
    await tester.drag(
      find.byKey(const Key('board-swipe-area')),
      const Offset(-300, 0),
    );
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const Key('board-swipe-area')),
      const Offset(-300, 0),
    );
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('task-1')).first),
    );
    await tester.pump(const Duration(milliseconds: 650));
    expect(find.byKey(const Key('drag-edge-left')), findsOneWidget);
    expect(find.byKey(const Key('drag-edge-right')), findsOneWidget);
    await gesture.moveTo(const Offset(10, 340));
    await tester.pump(const Duration(milliseconds: 550));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 550));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('column-todo')), findsOneWidget);
    expect(find.byKey(const Key('drag-edge-left')), findsOneWidget);
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
    await tester.pump(const Duration(milliseconds: 300));
    final second = find.byKey(const Key('task-2')).first;
    await gesture.moveTo(tester.getCenter(second) + const Offset(0, 40));
    await tester.pump(const Duration(milliseconds: 220));
    expect(find.byKey(const Key('drop-placeholder-todo')), findsOneWidget);
    await gesture.up();
    await tester.pumpAndSettle();
    final ordered = model.tasks(KanbanStatus.todo);
    expect(ordered.map((task) => task.id), ['2', '1']);
    expect(ordered.map((task) => task.sortOrder), [1, 1001]);
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
          .widget<Transform>(find.byKey(const Key('drag-overview-scale')))
          .transform
          .entry(0, 0),
      .9,
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
  testWidgets('filtered drop uses visible neighbours in the full task order', (
    tester,
  ) async {
    final repo = FakeKanbanRepository(
      tasks: [
        sampleTask('source', 'Show source', KanbanStatus.todo),
        sampleTask('hidden', 'Hidden', KanbanStatus.inProgress, order: 1000),
        sampleTask('first', 'Show first', KanbanStatus.inProgress, order: 2000),
        sampleTask(
          'second',
          'Show second',
          KanbanStatus.inProgress,
          order: 3000,
        ),
      ],
    );
    final model = await showBoard(tester, repo);
    model.setSearchQuery('Show');
    await tester.pumpAndSettle();
    final columns = tester.widgetList<KanbanStatusColumn>(
      find.byType(KanbanStatusColumn, skipOffstage: false),
    );
    final source = columns.firstWhere((c) => c.status == KanbanStatus.todo);
    final target = columns.firstWhere(
      (c) => c.status == KanbanStatus.inProgress,
    );
    source.onDragStart(
      model.allTasks.firstWhere((t) => t.id == 'source'),
      const Rect.fromLTWH(20, 200, 240, 80),
    );
    await tester.pump();
    target.onDrop('source', KanbanStatus.inProgress, 1, null);
    await tester.pumpAndSettle();
    expect(model.tasks(KanbanStatus.inProgress).map((t) => t.id), [
      'hidden',
      'first',
      'source',
      'second',
    ]);
    expect(repo.moveCalls, 1);
  });

  testWidgets('derived sorting offers Custom order before dragging', (
    tester,
  ) async {
    final model = await showBoard(
      tester,
      FakeKanbanRepository(tasks: [sampleTask('1', 'Task', KanbanStatus.todo)]),
    );
    model.setSort(KanbanSort.nearestDeadline);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<LongPressDraggable<String>>(
            find.byType(LongPressDraggable<String>).first,
          )
          .maxSimultaneousDrags,
      0,
    );
    await tester.tap(find.text('Use Custom order to drag tasks'));
    await tester.pumpAndSettle();
    expect(model.activeSort, KanbanSort.custom);
    expect(
      tester
          .widget<LongPressDraggable<String>>(
            find.byType(LongPressDraggable<String>).first,
          )
          .maxSimultaneousDrags,
      1,
    );
  });
}
