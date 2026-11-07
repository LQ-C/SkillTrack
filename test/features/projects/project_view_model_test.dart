import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:skilltrack/core/utils/date_formatter.dart';
import 'package:skilltrack/features/projects/models/project_with_progress.dart';
import 'package:skilltrack/features/projects/viewmodels/create_project_view_model.dart';
import 'package:skilltrack/features/projects/viewmodels/project_dashboard_view_model.dart';
import 'package:skilltrack/features/ai_task_generation/models/generated_task_draft.dart';
import 'package:skilltrack/features/ai_task_generation/models/task_generation_request.dart';
import '../kanban/fake_repository.dart';

import 'fake_project_repository.dart';

void main() {
  test(
    'dashboard mutation guard is shared and releases after failure',
    () async {
      final repo = _MutationGateRepository();
      final model = ProjectDashboardViewModel(repo);
      addTearDown(model.dispose);
      final first = model.archive('a');
      expect(model.isMutating, isTrue);
      expect(await model.delete('a'), isFalse);
      expect(await model.archive('a'), isFalse);
      expect(repo.archiveCalls, 1);
      expect(repo.deleteCalled, isFalse);
      repo.gate!.completeError(StateError('offline'));
      expect(await first, isFalse);
      expect(model.isMutating, isFalse);
      repo.gate = null;
      expect(await model.archive('a'), isTrue);
      expect(repo.archiveCalls, 2);
      expect(model.isMutating, isFalse);
    },
  );

  test(
    'initial preview edits and revision save only the final drafts',
    () async {
      final projects = FakeProjectRepository();
      final generation = FakeTaskGenerationRepository();
      final tasks = FakeKanbanRepository();
      final model = CreateProjectViewModel(
        (projects)..generatedTaskRepository = tasks,
        generationRepository: generation,
      );
      addTearDown(model.dispose);
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      model.setStartDate(today);
      model.setEndDate(today.add(const Duration(days: 7)));
      expect(
        await model.generateTaskPreview(
          name: 'Flutter',
          description: 'Study Flutter',
        ),
        hasLength(3),
      );
      final original = model.pendingGeneratedTasks.first;
      expect(
        model.updateGeneratedTask(0, original.copyWith(title: 'Step 2')),
        isFalse,
      );
      expect(
        model.updateGeneratedTask(0, original.copyWith(title: '')),
        isFalse,
      );
      expect(
        model.updateGeneratedTask(
          0,
          original.copyWith(deadline: today.subtract(const Duration(days: 1))),
        ),
        isFalse,
      );
      expect(
        model.updateGeneratedTask(
          0,
          original.copyWith(
            title: 'Custom step',
            checklist: ['Read docs', 'Practice'],
          ),
        ),
        isTrue,
      );
      model.removeGeneratedTask(1);
      model.reorderGeneratedTask(0, 2);
      expect(model.pendingGeneratedTasks.map((item) => item.position), [0, 1]);
      expect(projects.stored, isEmpty);
      expect(tasks.generatedInsertCalls, 0);
      generation.failRevision = true;
      expect(await model.reviseGeneratedTasks('  Add tests  '), isFalse);
      expect(model.pendingGeneratedTasks.last.title, 'Custom step');
      generation.failRevision = false;
      generation.revisionResult = [
        original.copyWith(title: 'Revised step', checklist: ['Review']),
      ];
      expect(await model.reviseGeneratedTasks('  Add tests  '), isTrue);
      expect(generation.lastSourceMode, TaskGenerationMode.initial);
      expect(generation.lastFeedback, 'Add tests');
      expect(generation.lastExistingTasks, isEmpty);
      expect(generation.lastCurrentDraft.last.title, 'Custom step');
      expect(model.pendingGeneratedTasks.single.title, 'Revised step');
      expect(
        model.updateGeneratedTask(
          0,
          model.pendingGeneratedTasks.single.copyWith(
            title: 'Final step',
            checklist: ['Final check'],
          ),
        ),
        isTrue,
      );
      expect(await model.confirmGeneratedTasks(), isNotNull);
      expect(generation.calls, 1);
      expect(generation.revisionCalls, 2);
      expect(projects.stored, hasLength(1));
      expect(tasks.stored.single.title, 'Final step');
      expect(tasks.stored.single.checklistItems.single.title, 'Final check');
    },
  );

  test('generation keeps drafts in memory until one confirmation', () async {
    final projects = FakeProjectRepository();
    final generation = FakeTaskGenerationRepository()
      ..pending = Completer<List<GeneratedTaskDraft>>();
    final tasks = FakeKanbanRepository();
    final model = CreateProjectViewModel(
      (projects)..generatedTaskRepository = tasks,
      generationRepository: generation,
    );
    addTearDown(model.dispose);
    final today = DateTime.now();
    model.setStartDate(DateTime(today.year, today.month, today.day));
    model.setEndDate(DateTime(today.year, today.month, today.day + 7));
    final first = model.generateTaskPreview(
      name: 'Flutter',
      description: 'Study',
    );
    expect(model.isGeneratingTasks, isTrue);
    expect(
      await model.generateTaskPreview(name: 'Flutter', description: 'Study'),
      isNull,
    );
    expect(await model.submit(name: 'Flutter', description: ''), isNull);
    final start = model.startDate!;
    generation.pending!.complete([
      for (var index = 0; index < 3; index++)
        GeneratedTaskDraft(
          title: 'Step $index',
          description: 'Study step $index',
          priority: 'medium',
          deadline: start,
          position: index,
        ),
    ]);
    expect(await first, hasLength(3));
    expect(generation.calls, 1);
    expect(model.isGeneratingTasks, isFalse);
    expect(model.pendingGeneratedTasks, hasLength(3));
    expect(() => model.pendingGeneratedTasks.clear(), throwsUnsupportedError);
    expect(projects.stored, isEmpty);
    expect(tasks.generatedInsertCalls, 0);
    expect(await model.confirmGeneratedTasks(), isNotNull);
    expect(projects.stored.length, 1);
    expect(tasks.generatedInsertCalls, 1);
  });
  test('generation requires a valid title and both dates', () async {
    final projects = FakeProjectRepository();
    final generation = FakeTaskGenerationRepository();
    final tasks = FakeKanbanRepository();
    final model = CreateProjectViewModel(
      (projects)..generatedTaskRepository = tasks,
      generationRepository: generation,
    );
    addTearDown(model.dispose);
    expect(await model.generateTaskPreview(name: '', description: ''), isNull);
    expect(model.nameError, 'Project name is required.');
    expect(generation.calls, 0);
    expect(
      await model.generateTaskPreview(name: 'Flutter', description: ''),
      isNull,
    );
    expect(model.descriptionError, 'Add a description to generate tasks.');
    expect(model.startDateError, isNotNull);
    expect(model.endDateError, isNotNull);
    expect(projects.stored, isEmpty);
  });

  test('generation failure keeps form data and creates no project', () async {
    final projects = FakeProjectRepository();
    final generation = FakeTaskGenerationRepository()..fail = true;
    final model = CreateProjectViewModel(
      (projects)..generatedTaskRepository = FakeKanbanRepository(),
      generationRepository: generation,
    );
    addTearDown(model.dispose);
    final today = DateTime.now();
    model.setStartDate(DateTime(today.year, today.month, today.day));
    model.setEndDate(DateTime(today.year, today.month, today.day + 7));
    expect(
      await model.generateTaskPreview(name: 'Flutter', description: 'Study'),
      isNull,
    );
    expect(
      model.errorMessage,
      'Tasks could not be generated. Please try again.',
    );
    expect(projects.stored, isEmpty);
    expect(model.isGeneratingTasks, isFalse);
    generation.fail = false;
    expect(
      await model.generateTaskPreview(name: 'Flutter', description: 'Study'),
      isNotNull,
    );
  });

  test(
    'cancel discards drafts but preserves dates and permits regeneration',
    () async {
      final projects = FakeProjectRepository();
      final generation = FakeTaskGenerationRepository();
      final tasks = FakeKanbanRepository();
      final model = CreateProjectViewModel(
        (projects)..generatedTaskRepository = tasks,
        generationRepository: generation,
      );
      addTearDown(model.dispose);
      final today = DateTime.now();
      final start = DateTime(today.year, today.month, today.day);
      final end = start.add(const Duration(days: 7));
      model.setStartDate(start);
      model.setEndDate(end);
      expect(
        await model.generateTaskPreview(name: 'Flutter', description: 'Study'),
        hasLength(3),
      );
      model.cancelGeneratedTaskPreview();
      expect(model.pendingGeneratedTasks, isEmpty);
      expect(model.startDate, start);
      expect(model.endDate, end);
      expect(projects.stored, isEmpty);
      expect(tasks.generatedInsertCalls, 0);
      expect(
        await model.generateTaskPreview(name: 'Flutter', description: 'Study'),
        hasLength(3),
      );
      expect(generation.calls, 2);
    },
  );

  test(
    'project creation failure retains drafts for confirmation retry',
    () async {
      final projects = FakeProjectRepository()..failBoardCreation = true;
      final generation = FakeTaskGenerationRepository();
      final model = CreateProjectViewModel(
        (projects)..generatedTaskRepository = FakeKanbanRepository(),
        generationRepository: generation,
      );
      addTearDown(model.dispose);
      final today = DateTime.now();
      model.setStartDate(DateTime(today.year, today.month, today.day));
      model.setEndDate(DateTime(today.year, today.month, today.day + 7));
      expect(
        await model.generateTaskPreview(name: 'Flutter', description: 'Study'),
        hasLength(3),
      );
      expect(await model.confirmGeneratedTasks(), isNull);
      expect(model.pendingGeneratedTasks, hasLength(3));
      expect(model.isConfirmingGeneratedTasks, isFalse);
      expect(projects.stored, isEmpty);
      projects.failBoardCreation = false;
      expect(await model.confirmGeneratedTasks(), isNotNull);
      expect(projects.stored, hasLength(1));
      expect(generation.calls, 1);
    },
  );

  test('concurrent Confirm calls create and insert only once', () async {
    final projects = _DelayedProjectRepository();
    final generation = FakeTaskGenerationRepository();
    final tasks = FakeKanbanRepository();
    final model = CreateProjectViewModel(
      (projects)..generatedTaskRepository = tasks,
      generationRepository: generation,
    );
    addTearDown(model.dispose);
    final today = DateTime.now();
    model.setStartDate(DateTime(today.year, today.month, today.day));
    model.setEndDate(DateTime(today.year, today.month, today.day + 7));
    expect(
      await model.generateTaskPreview(name: 'Flutter', description: 'Study'),
      hasLength(3),
    );
    final first = model.confirmGeneratedTasks();
    expect(model.isConfirmingGeneratedTasks, isTrue);
    expect(await model.confirmGeneratedTasks(), isNull);
    projects.release.complete();
    expect(await first, isNotNull);
    expect(projects.createCalls, 1);
    expect(projects.stored, hasLength(1));
    expect(tasks.generatedInsertCalls, 1);
    expect(generation.calls, 1);
  });

  test(
    'failed batch insert retries without another project or generation',
    () async {
      final projects = FakeProjectRepository();
      final generation = FakeTaskGenerationRepository();
      final tasks = FakeKanbanRepository()..failGeneratedInsert = true;
      final model = CreateProjectViewModel(
        (projects)..generatedTaskRepository = tasks,
        generationRepository: generation,
      );
      addTearDown(model.dispose);
      final today = DateTime.now();
      model.setStartDate(DateTime(today.year, today.month, today.day));
      model.setEndDate(DateTime(today.year, today.month, today.day + 7));
      expect(
        await model.generateTaskPreview(name: 'Flutter', description: 'Study'),
        hasLength(3),
      );
      expect(model.hasPendingConfirmation, isFalse);
      expect(await model.confirmGeneratedTasks(), isNull);
      expect(model.hasPendingConfirmation, isTrue);
      expect(projects.stored, isEmpty);
      expect(model.errorMessage, contains('could not be saved'));
      tasks.failGeneratedInsert = false;
      final result = await model.confirmGeneratedTasks();
      expect(result?.project.id, projects.stored.single.project.id);
      expect(projects.stored.length, 1);
      expect(generation.calls, 1);
      expect(projects.projectRequests.toSet(), hasLength(1));
      expect(tasks.generatedInsertCalls, 2);
      expect(tasks.stored.length, 3);
    },
  );

  test(
    'empty project retry reuses the exact request and returns the committed IDs',
    () async {
      final projects = FakeProjectRepository()..loseProjectResponseOnce = true;
      final model = CreateProjectViewModel(projects);
      addTearDown(model.dispose);
      expect(await model.submit(name: 'Build', description: 'Plan'), isNull);
      final original = projects.stored.single;
      final recovered = await model.submit(name: 'Build', description: 'Plan');
      expect(recovered?.project.id, original.project.id);
      expect(recovered?.boardId, original.boardId);
      expect(projects.projectRequests, hasLength(2));
      expect(projects.projectRequests.toSet(), hasLength(1));
      expect(projects.stored, hasLength(1));
    },
  );

  test('defensive task parser cleans malformed values', () {
    final start = DateTime(2026, 10, 16);
    final end = DateTime(2026, 10, 20);
    final tasks = GeneratedTaskDraft.parseTasks(
      {
        'milestones': [
          {
            'title': 'Foundation',
            'tasks': [
              {'title': ' A ', 'description': ' First ', 'priority': 'URGENT'},
              {'title': 'a', 'description': 'duplicate', 'priority': 'high'},
              {'title': 'B', 'description': 'Second', 'priority': 'HIGH'},
            ],
          },
          {
            'title': 'Build',
            'tasks': [
              {'title': 'C', 'description': 'Third', 'priority': 'low'},
            ],
          },
        ],
      },
      startDate: start,
      endDate: end,
    );
    expect(tasks.map((task) => task.title), ['A', 'B', 'C']);
    expect(tasks.map((task) => task.position), [0, 1, 2]);
    expect(tasks.first.deadline, start);
    expect(tasks.last.deadline, end);
    expect(tasks.first.priority, 'medium');
    expect(tasks[1].priority, 'high');
  });

  test('generated checklists are sanitized, capped, ordered and immutable', () {
    final longTitle = 'x' * 151;
    final tasks = GeneratedTaskDraft.parseTasks(
      {
        'milestones': [
          {
            'tasks': [
              {
                'title': 'One',
                'checklist': [
                  '  First  ',
                  ' ',
                  42,
                  'SECOND',
                  'first',
                  'second  ',
                  longTitle,
                  'Third',
                  'Fourth',
                  'Fifth',
                ],
              },
              {'title': 'Two'},
              {'title': 'Three', 'checklist': 'invalid'},
            ],
          },
        ],
      },
      startDate: DateTime(2026, 10, 16),
      endDate: DateTime(2026, 10, 20),
    );
    expect(tasks.first.checklist, [
      'First',
      'SECOND',
      'x' * 150,
      'Third',
      'Fourth',
    ]);
    expect(tasks[1].checklist, isEmpty);
    expect(tasks[2].checklist, isEmpty);
    expect(() => tasks.first.checklist.add('Extra'), throwsUnsupportedError);
    final source = ['Original'];
    final draft = GeneratedTaskDraft(
      title: 'Other',
      description: '',
      priority: 'medium',
      deadline: DateTime(2026, 10, 16),
      position: 0,
      checklist: source,
    );
    source.add('Changed');
    expect(draft.checklist, ['Original']);
  });

  test(
    'milestone parser rejects unusable plans and limits tasks to twelve',
    () {
      final start = DateTime(2026, 10, 16);
      final end = DateTime(2026, 11, 16);
      for (final response in [
        {'tasks': []},
        {'milestones': []},
        {
          'milestones': [
            {
              'tasks': [
                {'title': 'One'},
                {'title': 'one'},
              ],
            },
          ],
        },
      ]) {
        expect(
          () => GeneratedTaskDraft.parseTasks(
            response,
            startDate: start,
            endDate: end,
          ),
          throwsException,
        );
      }
      final tasks = GeneratedTaskDraft.parseTasks(
        {
          'milestones': [
            for (var milestone = 0; milestone < 5; milestone++)
              {
                'title': 'Milestone $milestone',
                'tasks': [
                  for (var task = 0; task < 6; task++)
                    {
                      'title': 'Task $milestone-$task',
                      'description': 'Learn',
                      'priority': 'medium',
                    },
                ],
              },
          ],
        },
        startDate: start,
        endDate: end,
      );
      expect(tasks.length, 12);
      expect(tasks.first.title, 'Task 0-0');
      expect(tasks.last.title, 'Task 1-5');
      expect(tasks.first.deadline, start);
      expect(tasks.last.deadline, end);
    },
  );
  test('dashboard loads only owned projects and calculates summary', () async {
    final repo = FakeProjectRepository(
      items: [
        sampleProject('1', 'Flutter', total: 8, completed: 3),
        sampleProject('2', 'Done', status: 'completed'),
        sampleProject('3', 'Other user', ownerId: 'user-2'),
      ],
    );
    final model = ProjectDashboardViewModel(repo);
    await model.load();
    expect(model.projects.length, 2);
    expect(model.totalCount, 2);
    expect(model.activeCount, 1);
    expect(model.completedCount, 1);
    expect(model.projects.first.progress, 3 / 8);
    expect(model.projects.last.progress, 0);
    model.dispose();
  });

  test('dashboard searches, filters, archives and deletes', () async {
    final repo = FakeProjectRepository(
      items: [sampleProject('1', 'Flutter'), sampleProject('2', 'Python')],
    );
    final model = ProjectDashboardViewModel(repo);
    await model.load();
    model.search('  FLUT  ');
    expect(model.visibleProjects.single.project.name, 'Flutter');
    model.search('');
    expect(await model.archive('1'), true);
    expect(model.visibleProjects.map((item) => item.project.name), ['Python']);
    model.filter('archived');
    expect(model.visibleProjects.single.project.name, 'Flutter');
    expect(await model.delete('1'), true);
    expect(repo.deleteCalled, true);
    expect(model.visibleProjects, isEmpty);
    model.dispose();
  });

  test(
    'creation validates name and dates, then creates project and board',
    () async {
      final repo = FakeProjectRepository();
      final model = CreateProjectViewModel(repo);
      expect(await model.submit(name: '   ', description: ''), null);
      expect(model.nameError, 'Project name is required.');
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      model.setStartDate(today.add(const Duration(days: 2)));
      model.setEndDate(today.add(const Duration(days: 1)));
      expect(await model.submit(name: 'Flutter', description: ''), null);
      expect(
        model.dateError,
        'End date cannot be earlier than the start date.',
      );
      expect(repo.stored, isEmpty);
      model.setStartDate(null);
      model.setEndDate(null);
      final created = await model.submit(
        name: '  Flutter  ',
        description: '  Study  ',
      );
      expect(created?.project.name, 'Flutter');
      expect(created?.project.description, 'Study');
      expect(created?.project.status, 'active');
      expect(created?.boardId, isNotNull);
      expect(repo.stored.single.project.id, created?.project.id);
      model.dispose();
    },
  );

  test('board creation failure leaves no project in dashboard', () async {
    final repo = FakeProjectRepository()..failBoardCreation = true;
    final model = CreateProjectViewModel(repo);
    expect(await model.submit(name: 'Flutter', description: ''), null);
    expect(
      model.errorMessage,
      'Unable to create the project. Please try again.',
    );
    expect(repo.stored, isEmpty);
    model.dispose();
  });

  test('editing a project updates its fields and status', () async {
    final repo = FakeProjectRepository(items: [sampleProject('1', 'Flutter')]);
    final model = CreateProjectViewModel(
      repo,
      original: repo.stored.single.project,
    );
    model.setStartDate(DateTime(2026, 10, 1));
    final result = await model.submit(
      name: '  Flutter Advanced  ',
      description: '  ',
      status: 'completed',
    );
    expect(result?.project.name, 'Flutter Advanced');
    expect(result?.project.description, null);
    expect(repo.stored.single.project.status, 'completed');
    expect(repo.stored.single.project.startDate, DateTime(2026, 10, 1));
    model.dispose();
  });

  test(
    'date state is normalized and later start corrects end with one update',
    () {
      final model = CreateProjectViewModel(FakeProjectRepository());
      addTearDown(model.dispose);
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      model.setEndDate(today.add(const Duration(hours: 19)));
      var notifications = 0;
      model.addListener(() => notifications++);
      final future = DateTime(today.year, today.month, today.day + 5, 13, 30);
      model.setStartDate(future);
      final expected = DateTime(future.year, future.month, future.day);
      expect(model.startDate, expected);
      expect(model.endDate, expected);
      expect(model.dateError, isNull);
      expect(notifications, 1);
      model.setEndDate(expected.add(const Duration(days: 1, hours: 8)));
      expect(model.endDate, expected.add(const Duration(days: 1)));
      model.setStartDate(null);
      model.setEndDate(null);
      expect(model.startDate, isNull);
      expect(model.endDate, isNull);
      expect(model.dateError, isNull);
    },
  );

  test(
    'today and same-day dates with different times can be submitted',
    () async {
      final repo = FakeProjectRepository();
      final model = CreateProjectViewModel(repo);
      addTearDown(model.dispose);
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      model.setStartDate(today.add(const Duration(hours: 20)));
      model.setEndDate(today.add(const Duration(hours: 6)));
      final result = await model.submit(name: 'Today', description: '');
      expect(result?.project.startDate, today);
      expect(result?.project.endDate, today);
      expect(model.dateError, isNull);
    },
  );

  test('past dates are rejected on change and again before creation', () async {
    final repo = FakeProjectRepository();
    final model = CreateProjectViewModel(repo);
    addTearDown(model.dispose);
    final now = DateTime.now();
    final yesterday = DateTime(now.year, now.month, now.day - 1, 23, 59);
    model.setStartDate(yesterday);
    expect(model.startDateError, 'Start date cannot be in the past.');
    expect(await model.submit(name: 'Invalid', description: ''), isNull);
    expect(repo.stored, isEmpty);
    model.setStartDate(null);
    model.setEndDate(yesterday);
    expect(model.endDateError, 'End date cannot be in the past.');
    expect(await model.submit(name: 'Invalid', description: ''), isNull);
    expect(repo.stored, isEmpty);
    model.setEndDate(null);
    expect(model.dateError, isNull);
  });

  test(
    'editing keeps stored past dates and does not correct dependent dates',
    () async {
      final repo = FakeProjectRepository(
        items: [sampleProject('1', 'History')],
      );
      final past = DateTime(2020, 1, 1);
      await repo.updateProject(
        repo.stored.single.project.copyWith(startDate: past, endDate: past),
      );
      final model = CreateProjectViewModel(
        repo,
        original: repo.stored.single.project,
      );
      addTearDown(model.dispose);
      expect(model.startDate, past);
      expect(model.endDate, past);
      expect(await model.submit(name: 'History', description: ''), isNotNull);
      model.setStartDate(DateTime(2020, 1, 2));
      expect(model.endDate, past);
      expect(
        model.endDateError,
        'End date cannot be earlier than the start date.',
      );
      expect(await model.submit(name: 'History', description: ''), isNull);
    },
  );
  test('confirmed project rejection leaves the preview editable', () async {
    final projects = FakeProjectRepository()..failBoardCreation = true;
    final model = CreateProjectViewModel(
      projects,
      generationRepository: FakeTaskGenerationRepository(),
    );
    addTearDown(model.dispose);
    final today = DateFormatter.today();
    model.setStartDate(today);
    model.setEndDate(today.add(const Duration(days: 7)));
    await model.generateTaskPreview(name: 'App', description: 'Build');
    expect(await model.confirmGeneratedTasks(), isNull);
    expect(model.hasPendingConfirmation, isFalse);
    expect(model.canCustomizeGeneratedTasks, isTrue);
    final plan = model.pendingGeneratedTasks;
    model.setGeneratedTaskPreview([
      plan.first.copyWith(title: 'Revised step'),
      ...plan.skip(1),
    ]);
    projects.failBoardCreation = false;
    expect(await model.confirmGeneratedTasks(), isNotNull);
    expect(
      projects.projectRequests.map((request) => request.id).toSet(),
      hasLength(2),
    );
    expect(
      projects.generatedTaskRepository!.stored.first.title,
      'Revised step',
    );
  });

  test(
    'initial confirmation retries a lost committed response without duplicates',
    () async {
      final projects = FakeProjectRepository();
      final tasks = FakeKanbanRepository()..loseGeneratedResponseOnce = true;
      final model = CreateProjectViewModel(
        (projects)..generatedTaskRepository = tasks,
        generationRepository: FakeTaskGenerationRepository(),
      );
      addTearDown(model.dispose);
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      model.setStartDate(today);
      model.setEndDate(today.add(const Duration(days: 7)));
      await model.generateTaskPreview(name: 'App', description: 'Build an app');
      expect(await model.confirmGeneratedTasks(), isNull);
      expect(tasks.stored, hasLength(3));
      final committed = projects.stored.single;
      final recovered = await model.confirmGeneratedTasks();
      expect(recovered?.project.id, committed.project.id);
      expect(recovered?.boardId, committed.boardId);
      expect(projects.projectRequests, hasLength(2));
      expect(projects.projectRequests.toSet(), hasLength(1));
      expect(tasks.stored, hasLength(3));
      expect(projects.stored, hasLength(1));
      expect(tasks.generatedRequestIds.toSet(), hasLength(1));
    },
  );
}

class _DelayedProjectRepository extends FakeProjectRepository {
  final release = Completer<void>();
  int createCalls = 0;

  @override
  Future<ProjectWithProgress> createProject({
    required String name,
    String? description,
    String? constraints,
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    createCalls++;
    await release.future;
    return super.createProject(
      name: name,
      description: description,
      constraints: constraints,
      startDate: startDate,
      endDate: endDate,
    );
  }
}

class _MutationGateRepository extends FakeProjectRepository {
  _MutationGateRepository() : super(items: [sampleProject('a', 'First')]);
  Completer<void>? gate = Completer<void>();
  int archiveCalls = 0;

  @override
  Future<void> archiveProject(String projectId) async {
    archiveCalls++;
    await gate?.future;
    await super.archiveProject(projectId);
  }
}
