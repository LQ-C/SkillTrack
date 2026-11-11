import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skilltrack/app/app_theme.dart';
import 'package:skilltrack/features/ai_task_generation/models/generated_milestone_draft.dart';
import 'package:skilltrack/features/ai_task_generation/models/generated_task_draft.dart';
import 'package:skilltrack/features/ai_task_generation/view_models/append_task_generation_view_model.dart';
import 'package:skilltrack/features/ai_task_generation/views/generated_task_preview_screen.dart';
import 'package:skilltrack/features/kanban/models/kanban_filter.dart';
import 'package:skilltrack/features/kanban/models/kanban_status.dart';
import 'package:skilltrack/features/kanban/models/kanban_task.dart';
import 'package:skilltrack/features/kanban/models/task_priority.dart';
import 'package:skilltrack/features/kanban/models/task_tag.dart';
import 'package:skilltrack/features/kanban/viewmodels/kanban_view_model.dart';
import 'package:skilltrack/features/kanban/views/kanban_board_screen.dart';
import 'package:skilltrack/features/kanban/widgets/filter_sheet.dart';
import 'package:skilltrack/features/kanban/widgets/kanban_task_card.dart';
import 'package:skilltrack/features/kanban/widgets/task_form_sheet.dart';
import 'package:skilltrack/features/projects/models/project_milestone.dart';
import 'package:skilltrack/features/projects/viewmodels/create_project_view_model.dart';

import '../kanban/fake_repository.dart';
import '../projects/fake_project_repository.dart';

const a = GeneratedMilestoneDraft(
  localId: 'stage-a',
  title: 'Authentication',
  position: 0,
);
const b = GeneratedMilestoneDraft(
  localId: 'stage-b',
  title: 'Verification',
  position: 1,
);
const saved = ProjectMilestone(
  id: 'saved-a',
  projectId: 'project-1',
  title: 'Authentication',
  position: 0,
);
const empty = ProjectMilestone(
  id: 'saved-empty',
  projectId: 'project-1',
  title: 'Release',
  position: 1,
);
final now = DateTime.now();
final today = DateTime(now.year, now.month, now.day);
final end = today.add(const Duration(days: 14));
GeneratedTaskDraft draft(
  String title,
  GeneratedMilestoneDraft? milestone, {
  int position = 0,
}) => GeneratedTaskDraft(
  title: title,
  description: 'Implement $title',
  priority: 'medium',
  deadline: end,
  position: position,
  checklist: ['Implement', 'Verify'],
  milestone: milestone,
);
Map<String, Object?> responseTask(String title, {String? id}) => {
  'title': title,
  'description': 'Implement $title',
  'priority': 'medium',
  'checklist': ['Implement', 'Verify'],
  'draftTaskId': ?id,
};

Future<CreateProjectViewModel> initial(
  FakeProjectRepository projects,
  FakeKanbanRepository tasks,
  FakeTaskGenerationRepository ai,
) async {
  final model = CreateProjectViewModel(
    (projects)..generatedTaskRepository = tasks,
    generationRepository: ai,
  );
  model.setStartDate(today);
  model.setEndDate(end);
  await model.generateTaskPreview(
    name: 'App',
    description: 'Build an app',
    constraints: 'Flutter only',
  );
  return model;
}

FakeProjectRepository projectRepository() {
  final sample = sampleProject('project-1', 'App', boardId: 'board-1');
  return FakeProjectRepository(
    items: [
      sample.copyWith(
        project: sample.project.copyWith(
          description: 'Build an app',
          startDate: today,
          endDate: end,
        ),
      ),
    ],
  )..milestones.addAll([saved, empty]);
}

void main() {
  test(
    'task membership round trips, copies, equality and old ungrouped rows',
    () {
      final original = sampleTask(
        '1',
        'Login',
        KanbanStatus.todo,
      ).copyWith(milestoneId: saved.id);
      final parsed = KanbanTask.fromMap({
        ...original.toMap(),
        'created_at': original.createdAt.toIso8601String(),
        'updated_at': original.updatedAt.toIso8601String(),
      });
      expect(parsed.milestoneId, saved.id);
      expect(original.copyWith(), original);
      expect(original.copyWith().hashCode, original.hashCode);
      expect(original.copyWith(clearMilestone: true), isNot(original));
      expect(original.copyWith(title: 'Renamed').milestoneId, saved.id);
      final old = {...original.toMap()}..remove('milestone_id');
      expect(KanbanTask.fromMap(old).milestoneId, isNull);
    },
  );

  test(
    'parser preserves group ordering and identity independently of duplicate titles',
    () {
      final parsed = GeneratedTaskDraft.parseTasks(
        {
          'milestones': [
            {
              'localId': 'one',
              'title': 'Same title',
              'tasks': [responseTask('A'), responseTask('B')],
            },
            {
              'localId': 'two',
              'title': 'Same title',
              'tasks': [responseTask('C')],
            },
          ],
        },
        startDate: today,
        endDate: end,
      );
      expect(parsed.map((t) => t.milestone!.localId), ['one', 'one', 'two']);
      expect(parsed.map((t) => t.milestone!.position), [0, 0, 1]);
      expect(parsed.map((t) => t.position), [0, 1, 2]);
      expect(parsed.first.checklist, ['Implement', 'Verify']);
      expect(
        parsed.every(
          (t) => !t.deadline.isBefore(today) && !t.deadline.isAfter(end),
        ),
        isTrue,
      );
      expect(
        parsed.first.toRevisionJson()['milestone'],
        parsed.first.milestone!.toJson(),
      );
    },
  );

  test('revision preserves stable group and renamed task identities', () {
    final original = draft('Old task', a);
    final parsed = GeneratedTaskDraft.parseTasks(
      {
        'milestones': [
          {
            'localId': a.localId,
            'title': 'Renamed stage',
            'tasks': [responseTask('Renamed task', id: original.localId)],
          },
        ],
      },
      startDate: today,
      endDate: end,
      minimumTaskCount: 1,
      previousDraft: [original],
    );
    expect(parsed.single.localId, original.localId);
    expect(parsed.single.milestone!.localId, a.localId);
    expect(parsed.single.milestone!.title, 'Renamed stage');
  });

  test(
    'saved references use canonical metadata and unknown or duplicate identities fail',
    () {
      final response = {
        'milestones': [
          {
            'existingMilestoneId': saved.id,
            'title': 'Tampered',
            'tasks': [responseTask('A')],
          },
        ],
      };
      final parsed = GeneratedTaskDraft.parseTasks(
        response,
        startDate: today,
        endDate: end,
        minimumTaskCount: 1,
        existingMilestones: [saved],
      );
      expect(parsed.single.milestone!.title, saved.title);
      expect(parsed.single.milestone!.localId, 'saved:${saved.id}');
      expect(
        () => GeneratedTaskDraft.parseTasks(
          response,
          startDate: today,
          endDate: end,
          minimumTaskCount: 1,
        ),
        throwsException,
      );
      expect(
        () => GeneratedTaskDraft.parseTasks(
          {
            'milestones': [
              {
                'localId': 'same',
                'title': 'A',
                'tasks': [responseTask('A')],
              },
              {
                'localId': 'same',
                'title': 'B',
                'tasks': [responseTask('B')],
              },
            ],
          },
          startDate: today,
          endDate: end,
          minimumTaskCount: 1,
        ),
        throwsException,
      );
    },
  );

  test(
    'initial preview renames, reassigns and constrains reorder locally; Cancel writes nothing',
    () async {
      final projects = FakeProjectRepository(), tasks = FakeKanbanRepository();
      final ai = FakeTaskGenerationRepository()
        ..result = [draft('A', a), draft('B', a), draft('C', b)];
      final model = await initial(projects, tasks, ai);
      addTearDown(model.dispose);
      final identity = model.pendingGeneratedTasks.first.localId;
      expect(model.renameGeneratedMilestone(a.localId, 'Auth ready'), isTrue);
      expect(
        model.pendingGeneratedTasks
            .take(2)
            .every((t) => t.milestone!.title == 'Auth ready'),
        isTrue,
      );
      model.reorderGeneratedTask(0, 3);
      expect(model.pendingGeneratedTasks.first.localId, identity);
      expect(model.errorMessage, contains('within a milestone'));
      expect(
        model.updateGeneratedTask(
          0,
          model.pendingGeneratedTasks.first.copyWith(milestone: b),
        ),
        isTrue,
      );
      expect(
        model.pendingGeneratedTasks
            .where((t) => t.localId == identity)
            .single
            .milestone!
            .localId,
        b.localId,
      );
      final lastA = model.pendingGeneratedTasks.indexWhere(
        (t) => t.milestone!.localId == a.localId,
      );
      model.removeGeneratedTask(lastA);
      expect(model.availableGeneratedMilestones.map((g) => g.localId), [
        b.localId,
      ]);
      model.cancelGeneratedTaskPreview();
      expect(projects.stored, isEmpty);
      expect(tasks.stored, isEmpty);
      expect(tasks.generatedInsertCalls, 0);
    },
  );

  test(
    'initial confirmation saves final membership and retry retains one request',
    () async {
      final projects = FakeProjectRepository(),
          tasks = FakeKanbanRepository()..loseGeneratedResponseOnce = true;
      final ai = FakeTaskGenerationRepository()
        ..result = [draft('A', a), draft('B', a), draft('C', b)];
      final model = await initial(projects, tasks, ai);
      addTearDown(model.dispose);
      expect(await model.confirmGeneratedTasks(), isNull);
      expect(await model.confirmGeneratedTasks(), isNotNull);
      expect(tasks.generatedRequestIds.toSet(), hasLength(1));
      expect(tasks.stored, hasLength(3));
      expect(tasks.stored.map((t) => t.milestoneId), [
        a.localId,
        a.localId,
        b.localId,
      ]);
    },
  );

  test(
    'append/revision forwards canonical groups and membership; failed revision preserves preview',
    () async {
      final projects = projectRepository();
      final tasks = FakeKanbanRepository(
        tasks: [
          sampleTask(
            '1',
            'Saved',
            KanbanStatus.completed,
          ).copyWith(milestoneId: saved.id),
        ],
      );
      final ai = FakeTaskGenerationRepository()
        ..result = [draft('New', GeneratedMilestoneDraft.existing(saved))];
      final model = AppendTaskGenerationViewModel(
        projectId: 'project-1',
        boardId: 'board-1',
        projectRepository: projects,
        taskRepository: tasks,
        generationRepository: ai,
      );
      addTearDown(model.dispose);
      await model.generateMoreTasks(constraints: 'Flutter only');
      expect(ai.lastProjectId, 'project-1');
      expect(ai.lastMilestones, [saved, empty]);
      expect(ai.lastExistingTasks.single.milestoneId, saved.id);
      expect(
        model.renameGeneratedMilestone('saved:${saved.id}', 'Forbidden'),
        isFalse,
      );
      final before = model.pendingGeneratedTasks.single;
      ai.failRevision = true;
      expect(await model.reviseGeneratedTasks('Add tests'), isFalse);
      expect(model.pendingGeneratedTasks.single, same(before));
      ai.failRevision = false;
      expect(await model.reviseGeneratedTasks('Add tests'), isTrue);
      expect(
        ai.lastCurrentDraft.single.milestone!.existingMilestoneId,
        saved.id,
      );
      expect(ai.lastRevisionConstraints, 'Flutter only');
      expect(await model.confirmGeneratedTasks(), isTrue);
      expect(tasks.stored.first.title, 'Saved');
      expect(tasks.stored.last.milestoneId, saved.id);
    },
  );

  test(
    'milestone filtering combines search, status, priority, tags and dates; progress ignores filters',
    () async {
      const tag = TaskTag(
        id: 'tag',
        ownerId: 'user-1',
        name: 'Test',
        colorHex: '#5C6BC0',
      );
      final tasks = FakeKanbanRepository(
        tasks: [
          sampleTask(
            '1',
            'Login high',
            KanbanStatus.todo,
            priority: TaskPriority.high,
            tags: [tag],
            deadline: end,
          ).copyWith(milestoneId: saved.id),
          sampleTask(
            '2',
            'Finished',
            KanbanStatus.completed,
          ).copyWith(milestoneId: saved.id),
          sampleTask(
            '3',
            'Archived',
            KanbanStatus.completed,
          ).copyWith(milestoneId: saved.id, isArchived: true),
          sampleTask('4', 'Ungrouped', KanbanStatus.todo),
        ],
      );
      final model = KanbanViewModel(
        tasks,
        projectRepository: projectRepository(),
        projectId: 'project-1',
      );
      addTearDown(model.dispose);
      await model.initialize('board-1');
      model.setSearchQuery('Login');
      model.applyFilter(
        KanbanFilter(
          milestoneId: saved.id,
          priorities: {TaskPriority.high},
          statuses: {KanbanStatus.todo},
          tagIds: {tag.id},
          deadlineStart: today,
          deadlineEnd: end,
        ),
      );
      expect(model.visibleTasks(KanbanStatus.todo).map((t) => t.id), ['1']);
      expect(model.milestoneProgress(saved.id), (completed: 1, total: 2));
      expect(model.milestoneProgress(empty.id), (completed: 0, total: 0));
      expect(model.projectProgress, closeTo(1 / 3, .001));
      model.setSearchQuery('');
      model.applyFilter(KanbanFilter(noMilestoneOnly: true));
      expect(model.visibleTasks(KanbanStatus.todo).single.id, '4');
      model.clearFilters();
      expect(model.visibleTasks(KanbanStatus.todo), hasLength(2));
    },
  );

  test(
    'movement, archive/restore, duplication, editing and manual creation retain optional membership',
    () async {
      final tasks = FakeKanbanRepository(
        tasks: [
          sampleTask(
            '1',
            'Login',
            KanbanStatus.todo,
          ).copyWith(milestoneId: saved.id),
        ],
      );
      final model = KanbanViewModel(
        tasks,
        projectRepository: projectRepository(),
        projectId: 'project-1',
      );
      addTearDown(model.dispose);
      await model.initialize('board-1');
      expect(await model.moveTask('1', KanbanStatus.inProgress), isTrue);
      expect(model.allTasks.single.milestoneId, saved.id);
      expect(model.allTasks.single.isTracking, isTrue);
      expect(await model.archiveTask('1'), isTrue);
      expect(await model.restoreTask('1'), isTrue);
      expect(model.allTasks.single.milestoneId, saved.id);
      expect(await model.duplicateTask(model.allTasks.single), isTrue);
      expect(model.allTasks.every((t) => t.milestoneId == saved.id), isTrue);
      final task = model.allTasks.first;
      expect(
        await model.updateTask(
          task,
          title: task.title,
          description: task.description,
          status: task.status,
          priority: task.priority,
          clearMilestone: true,
        ),
        isTrue,
      );
      expect(model.allTasks.first.milestoneId, isNull);
      expect(
        await model.createTask(title: 'Manual', milestoneId: empty.id),
        isTrue,
      );
      expect(model.allTasks.last.milestoneId, empty.id);
    },
  );

  testWidgets('grouped preview renames and reassigns through existing editor', (
    tester,
  ) async {
    final model = await initial(
      FakeProjectRepository(),
      FakeKanbanRepository(),
      FakeTaskGenerationRepository()
        ..result = [draft('A', a), draft('B', a), draft('C', b)],
    );
    addTearDown(model.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: GeneratedTaskPreviewScreen(viewModel: model),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('milestone-${a.localId}')), findsOneWidget);
    await tester.enterText(
      find.byKey(ValueKey('milestone-${a.localId}')),
      'Login ready',
    );
    expect(model.pendingGeneratedTasks.first.milestone!.title, 'Login ready');
    await tester.tap(find.byTooltip('Edit generated task').first);
    await tester.pumpAndSettle();
    final selector = find.byKey(const Key('generated-edit-milestone'));
    await tester.ensureVisible(selector);
    await tester.tap(selector);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Verification').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-generated-edit')));
    await tester.pumpAndSettle();
    expect(
      model.pendingGeneratedTasks
          .where((t) => t.title == 'A')
          .single
          .milestone!
          .localId,
      b.localId,
    );
    expect(tester.takeException(), isNull);
  });

  for (final size in [const Size(320, 740), const Size(900, 1000)]) {
    testWidgets(
      'board milestones, progress and filter fit $size with scaled text',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final tasks = FakeKanbanRepository(
          tasks: [
            sampleTask(
              '1',
              'Login',
              KanbanStatus.todo,
            ).copyWith(milestoneId: saved.id),
          ],
        );
        final model = KanbanViewModel(
          tasks,
          projectRepository: projectRepository(),
          projectId: 'project-1',
        );
        addTearDown(model.dispose);
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.light,
            home: MediaQuery(
              data: MediaQueryData(
                size: size,
                textScaler: TextScaler.linear(1.4),
              ),
              child: KanbanBoardScreen(
                viewModel: model,
                projectId: 'project-1',
                boardId: 'board-1',
                projectName: 'App',
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Milestone · Authentication'), findsWidgets);
        await tester.tap(find.text('Milestones'));
        await tester.pumpAndSettle();
        expect(find.text('0/1 completed'), findsOneWidget);
        expect(find.text('No tasks'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.light,
            home: Scaffold(body: FilterSheet(viewModel: model)),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('milestone-filter')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('No milestone').last);
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Apply filters'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Apply filters'));
        await tester.pumpAndSettle();
        expect(model.activeFilter.noMilestoneOnly, isTrue);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('manual task editor selector uses saved membership', (
    tester,
  ) async {
    final task = sampleTask(
      '1',
      'Login',
      KanbanStatus.todo,
    ).copyWith(milestoneId: saved.id);
    final model = KanbanViewModel(
      FakeKanbanRepository(tasks: [task]),
      projectRepository: projectRepository(),
      projectId: 'project-1',
    );
    addTearDown(model.dispose);
    await model.initialize('board-1');
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: TaskFormSheet(viewModel: model, task: task),
      ),
    );
    await tester.pumpAndSettle();
    final selector = find.byKey(const Key('task-milestone'));
    await tester.ensureVisible(selector);
    expect(find.text(saved.title), findsOneWidget);
    await tester.tap(selector);
    await tester.pumpAndSettle();
    await tester.tap(find.text('No milestone').last);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'card displays associated milestone on a solid readable surface',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: KanbanTaskCard(
              task: sampleTask('1', 'Login', KanbanStatus.todo),
              milestoneTitle: saved.title,
              onTap: () {},
              onAction: (_) {},
            ),
          ),
        ),
      );
      expect(find.text('Milestone · Authentication'), findsOneWidget);
    },
  );
  testWidgets('long-press edge drag preserves milestone label and membership', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final tasks = FakeKanbanRepository(
      tasks: [
        sampleTask(
          '1',
          'Login',
          KanbanStatus.todo,
        ).copyWith(milestoneId: saved.id),
      ],
    );
    final model = KanbanViewModel(
      tasks,
      projectRepository: projectRepository(),
      projectId: 'project-1',
    );
    addTearDown(model.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: KanbanBoardScreen(
          viewModel: model,
          projectId: 'project-1',
          boardId: 'board-1',
          projectName: 'App',
        ),
      ),
    );
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('task-1')).first),
    );
    await tester.pump(const Duration(milliseconds: 650));
    await gesture.moveTo(const Offset(380, 340));
    await tester.pump(const Duration(milliseconds: 550));
    await tester.pump(const Duration(milliseconds: 300));
    await gesture.moveTo(const Offset(190, 350));
    await tester.pump();
    expect(
      find.byKey(const Key('drop-placeholder-in_progress')),
      findsOneWidget,
    );
    await gesture.up();
    await tester.pumpAndSettle();
    expect(model.allTasks.single.status, KanbanStatus.inProgress);
    expect(model.allTasks.single.milestoneId, saved.id);
    expect(find.text('Milestone · Authentication'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  test(
    'empty milestone rename stays local and blocks saving until corrected',
    () async {
      final tasks = FakeKanbanRepository();
      final model = await initial(
        FakeProjectRepository(),
        tasks,
        FakeTaskGenerationRepository()
          ..result = [draft('A', a), draft('B', a), draft('C', b)],
      );
      addTearDown(model.dispose);
      expect(model.renameGeneratedMilestone(a.localId, ''), isFalse);
      expect(await model.confirmGeneratedTasks(), isNull);
      expect(tasks.generatedInsertCalls, 0);
      expect(
        model.renameGeneratedMilestone(a.localId, 'Authentication ready'),
        isTrue,
      );
      expect(await model.confirmGeneratedTasks(), isNotNull);
    },
  );
  test(
    'revision rejects one stable task identity reused for two different tasks',
    () {
      final old = draft('Old', a);
      expect(
        () => GeneratedTaskDraft.parseTasks(
          {
            'milestones': [
              {
                'localId': a.localId,
                'title': a.title,
                'tasks': [
                  responseTask('One', id: old.localId),
                  responseTask('Two', id: old.localId),
                ],
              },
            ],
          },
          startDate: today,
          endDate: end,
          minimumTaskCount: 1,
          previousDraft: [old],
        ),
        throwsException,
      );
    },
  );
}
