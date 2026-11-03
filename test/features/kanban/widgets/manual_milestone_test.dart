import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skilltrack/app/app_theme.dart';
import 'package:skilltrack/app/router/app_router.dart';
import 'package:skilltrack/core/errors/app_exception.dart';
import 'package:skilltrack/features/kanban/models/kanban_filter.dart';
import 'package:skilltrack/features/kanban/models/kanban_status.dart';
import 'package:skilltrack/features/kanban/models/kanban_task.dart';
import 'package:skilltrack/features/kanban/viewmodels/kanban_view_model.dart';
import 'package:skilltrack/features/kanban/views/kanban_board_screen.dart';
import 'package:skilltrack/features/kanban/widgets/filter_sheet.dart';
import 'package:skilltrack/features/kanban/widgets/milestone_progress_section.dart';
import 'package:skilltrack/features/kanban/widgets/task_form_sheet.dart';
import 'package:skilltrack/features/projects/models/project_milestone.dart';

import '../fake_repository.dart';
import '../../projects/fake_project_repository.dart';

FakeProjectRepository _projects() => FakeProjectRepository(
  items: [sampleProject('project-1', 'Learning', boardId: 'board-1')],
);

Future<KanbanViewModel> _model(
  FakeProjectRepository projects, [
  FakeKanbanRepository? tasks,
]) async {
  final model = KanbanViewModel(
    tasks ?? FakeKanbanRepository(),
    projectRepository: projects,
    projectId: 'project-1',
  );
  await model.initialize('board-1');
  return model;
}

Future<void> _showForm(
  WidgetTester tester,
  KanbanViewModel model, {
  KanbanTask? task,
  Size size = const Size(390, 844),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light,
      initialRoute: '/form',
      routes: {
        '/': (_) => const Scaffold(body: Text('Board destination')),
        '/form': (_) => TaskFormSheet(viewModel: model, task: task),
      },
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openDialog(WidgetTester tester) async {
  tester.testTextInput.hide();
  await tester.pumpAndSettle();
  final button = find.byKey(const Key('create-milestone-button'));
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button);
  await tester.pumpAndSettle();
}

Future<void> _create(WidgetTester tester, String name) async {
  await tester.enterText(find.byKey(const Key('milestone-name-field')), name);
  await tester.tap(find.byKey(const Key('confirm-milestone-button')));
  await tester.pumpAndSettle();
}

void main() {
  test('title validation trims and enforces 1–150 Unicode characters', () {
    expect(
      ProjectMilestone.validateTitle('  \t\n'),
      AppErrorMessages.milestoneNameRequired,
    );
    expect(
      ProjectMilestone.validateTitle('x' * 151),
      AppErrorMessages.milestoneNameTooLong,
    );
    expect(ProjectMilestone.validateTitle('  ${'x' * 150}  '), isNull);
    expect(ProjectMilestone.validateTitle('😀' * 150), isNull);
  });

  test(
    'ViewModel creates and publishes progress/filter state without creating tasks',
    () async {
      final projects = _projects();
      final tasks = FakeKanbanRepository();
      final model = await _model(projects, tasks);
      addTearDown(model.dispose);
      var notifications = 0;
      model.addListener(() => notifications++);
      final created = await model.createMilestone('  Build  ');
      expect(created!.title, 'Build');
      expect(created.projectId, 'project-1');
      expect(model.availableMilestones.single.id, created.id);
      expect(model.milestoneProgress(created.id), (completed: 0, total: 0));
      model.applyFilter(KanbanFilter(milestoneId: created.id));
      expect(model.activeFilter.milestoneId, created.id);
      expect(tasks.stored, isEmpty);
      expect(notifications, greaterThanOrEqualTo(2));
    },
  );

  test(
    'pending milestone create blocks duplicate calls and retries reuse the operation ID',
    () async {
      final projects = _projects()..milestonePending = Completer<void>();
      final model = await _model(projects);
      addTearDown(model.dispose);
      final pending = model.createMilestone('Plan');
      expect(model.isCreatingMilestone, isTrue);
      expect(await model.createMilestone('Plan'), isNull);
      expect(projects.milestoneCreateCalls, 1);
      projects.failMilestoneCreate = true;
      projects.milestonePending!.complete();
      expect(await pending, isNull);
      expect(model.isCreatingMilestone, isFalse);
      expect(model.milestoneError, AppErrorMessages.createMilestoneFailed);
      projects.milestonePending = null;
      projects.failMilestoneCreate = false;
      expect(await model.createMilestone(' Plan '), isNotNull);
      expect(projects.milestoneRequestIds[0], projects.milestoneRequestIds[1]);
    },
  );

  test('lost response retry returns the persisted milestone once', () async {
    final projects = _projects()..loseMilestoneResponseOnce = true;
    final model = await _model(projects);
    addTearDown(model.dispose);
    expect(await model.createMilestone('Plan'), isNull);
    expect(projects.milestones, hasLength(1));
    expect(await model.createMilestone('Plan'), isNotNull);
    expect(projects.milestones, hasLength(1));
    expect(model.availableMilestones, hasLength(1));
    expect(projects.milestoneRequestIds.toSet(), hasLength(1));
  });

  test('editing a failed request name gets a new operation ID', () async {
    final projects = _projects()..failMilestoneCreate = true;
    final model = await _model(projects);
    addTearDown(model.dispose);
    await model.createMilestone('Before');
    projects.failMilestoneCreate = false;
    expect((await model.createMilestone('After'))!.title, 'After');
    expect(projects.milestoneRequestIds.toSet(), hasLength(2));
  });

  test(
    'validation, signed-out, foreign and archived project/board restrictions',
    () async {
      for (final projects in [
        _projects()..userId = null,
        FakeProjectRepository(
          items: [
            sampleProject(
              'project-1',
              'Other',
              ownerId: 'other',
              boardId: 'board-1',
            ),
          ],
        ),
        FakeProjectRepository(
          items: [
            sampleProject(
              'project-1',
              'Archived',
              status: 'archived',
              boardId: 'board-1',
            ),
          ],
        ),
        FakeProjectRepository(
          items: [
            sampleProject('project-1', 'Wrong board', boardId: 'board-other'),
          ],
        ),
      ]) {
        final model = await _model(projects);
        expect(model.canCreateMilestone, isFalse);
        expect(await model.createMilestone('Plan'), isNull);
        expect(projects.milestoneCreateCalls, 0);
        model.dispose();
      }
      final projects = _projects();
      final model = await _model(projects);
      addTearDown(model.dispose);
      for (final name in ['', '  ', 'x' * 151]) {
        expect(await model.createMilestone(name), isNull);
      }
      expect(projects.milestoneCreateCalls, 0);
      expect(await model.archiveBoard(), isTrue);
      expect(model.canCreateMilestone, isFalse);
      expect(await model.createMilestone('Plan'), isNull);
    },
  );

  testWidgets('selector and No milestone remain visible without milestones', (
    tester,
  ) async {
    final model = await _model(_projects());
    addTearDown(model.dispose);
    await _showForm(tester, model);
    expect(find.byKey(const Key('task-milestone')), findsOneWidget);
    expect(find.text('No milestone'), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(find.byKey(const Key('create-milestone-button')))
          .onPressed,
      isNotNull,
    );
  });

  for (final edit in [false, true]) {
    testWidgets(
      '${edit ? 'Edit' : 'Add'} Task auto-selects created milestone and saves membership',
      (tester) async {
        final projects = _projects();
        final task = edit
            ? sampleTask('t', 'Existing task', KanbanStatus.todo)
            : null;
        final tasks = FakeKanbanRepository(tasks: [?task]);
        final model = await _model(projects, tasks);
        addTearDown(model.dispose);
        await _showForm(tester, model, task: task);
        await tester.enterText(
          find.byKey(const Key('task-title-field')),
          'Keep title',
        );
        await _openDialog(tester);
        expect(
          find.text('Saved immediately, even if you cancel the task form.'),
          findsOneWidget,
        );
        await _create(tester, '  Testing  ');
        expect(find.byType(AlertDialog), findsNothing);
        expect(
          tester
              .widget<DropdownButtonFormField<String>>(
                find.byKey(const Key('task-milestone')),
              )
              .initialValue,
          projects.milestones.single.id,
        );
        expect(
          tester
              .widget<TextFormField>(find.byKey(const Key('task-title-field')))
              .controller!
              .text,
          'Keep title',
        );
        await tester.tap(find.byKey(const Key('save-task-button')));
        await tester.pumpAndSettle();
        expect(tasks.stored.single.milestoneId, projects.milestones.single.id);
        expect(tasks.stored.single.title, 'Keep title');
        expect(find.text('Board destination'), findsOneWidget);
      },
    );
  }

  testWidgets(
    'dialog cancel and successful creation followed by task cancel preserve input and saved milestone',
    (tester) async {
      final projects = _projects();
      final tasks = FakeKanbanRepository();
      final model = await _model(projects, tasks);
      addTearDown(model.dispose);
      await _showForm(tester, model);
      await tester.enterText(
        find.byKey(const Key('task-title-field')),
        'Retained title',
      );
      await _openDialog(tester);
      await tester.enterText(
        find.byKey(const Key('milestone-name-field')),
        'Cancelled',
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(projects.milestones, isEmpty);
      expect(
        tester
            .widget<TextFormField>(find.byKey(const Key('task-title-field')))
            .controller!
            .text,
        'Retained title',
      );
      await _openDialog(tester);
      await _create(tester, 'Saved');
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(projects.milestones.single.title, 'Saved');
      expect(tasks.stored, isEmpty);
      expect(find.text('Board destination'), findsOneWidget);
    },
  );

  testWidgets(
    'dialog shows validation, retains failed input, blocks double tap and allows retry',
    (tester) async {
      final projects = _projects();
      final model = await _model(projects);
      addTearDown(model.dispose);
      await _showForm(tester, model);
      await _openDialog(tester);
      for (final name in ['   ', 'x' * 151]) {
        await _create(tester, name);
        expect(
          find.text(
            name.trim().isEmpty
                ? AppErrorMessages.milestoneNameRequired
                : AppErrorMessages.milestoneNameTooLong,
          ),
          findsOneWidget,
        );
        expect(projects.milestoneCreateCalls, 0);
      }
      projects.milestonePending = Completer<void>();
      projects.failMilestoneCreate = true;
      await tester.enterText(
        find.byKey(const Key('milestone-name-field')),
        'Retry name',
      );
      final confirm = find.byKey(const Key('confirm-milestone-button'));
      await tester.tap(confirm);
      await tester.tap(confirm);
      await tester.pump();
      expect(projects.milestoneCreateCalls, 1);
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Cancel'))
            .onPressed,
        isNull,
      );
      projects.milestonePending!.complete();
      await tester.pumpAndSettle();
      expect(find.text(AppErrorMessages.createMilestoneFailed), findsOneWidget);
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const Key('milestone-name-field')),
            )
            .controller!
            .text,
        'Retry name',
      );
      projects.milestonePending = null;
      projects.failMilestoneCreate = false;
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(projects.milestones.single.title, 'Retry name');
      expect(projects.milestoneRequestIds.toSet(), hasLength(1));
    },
  );

  testWidgets(
    'archived project leaves selector available and disables creation',
    (tester) async {
      final projects = FakeProjectRepository(
        items: [
          sampleProject(
            'project-1',
            'Archived',
            status: 'archived',
            boardId: 'board-1',
          ),
        ],
      );
      final model = await _model(projects);
      addTearDown(model.dispose);
      await _showForm(tester, model);
      expect(find.byKey(const Key('task-milestone')), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(
              find.byKey(const Key('create-milestone-button')),
            )
            .onPressed,
        isNull,
      );
    },
  );

  testWidgets(
    'board refresh after task cancellation loads created milestone in progress and filters',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final projects = _projects();
      final tasks = FakeKanbanRepository();
      final model = await _model(projects, tasks);
      addTearDown(model.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          onGenerateRoute: AppRouter(
            projectRepository: projects,
            kanbanRepository: tasks,
          ).onGenerateRoute,
          home: KanbanBoardScreen(
            viewModel: model,
            projectId: 'project-1',
            boardId: 'board-1',
            projectName: 'Learning',
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('New Task'));
      await tester.pumpAndSettle();
      await _openDialog(tester);
      await _create(tester, 'Board milestone');
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(tasks.stored, isEmpty);
      expect(model.availableMilestones.single.title, 'Board milestone');
      expect(find.byType(MilestoneProgressSection), findsOneWidget);
      await tester.tap(find.text('Milestones'));
      await tester.pumpAndSettle();
      expect(find.text('Board milestone'), findsOneWidget);
      expect(find.text('No tasks'), findsOneWidget);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(body: FilterSheet(viewModel: model)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('milestone-filter')));
      await tester.tap(find.byKey(const Key('milestone-filter')));
      await tester.pumpAndSettle();
      expect(find.text('Board milestone').last, findsOneWidget);
    },
  );

  for (final size in [const Size(320, 640), const Size(900, 1200)]) {
    testWidgets('milestone dialog fits $size without overflow', (tester) async {
      final model = await _model(_projects());
      addTearDown(model.dispose);
      await _showForm(tester, model, size: size);
      await _openDialog(tester);
      await _create(tester, 'Long name ' * 10);
      expect(tester.takeException(), isNull);
    });
  }
}
