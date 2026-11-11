import 'package:skilltrack/features/kanban/repositories/kanban_repository.dart';
import 'package:skilltrack/features/ai_task_generation/models/generated_milestone_draft.dart';
import 'package:skilltrack/features/projects/models/project_milestone.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:skilltrack/core/errors/app_exception.dart';
import 'package:skilltrack/features/ai_task_generation/models/generated_task_draft.dart';
import 'package:skilltrack/features/ai_task_generation/models/task_generation_request.dart';
import 'package:skilltrack/features/ai_task_generation/services/ai_task_generation_service.dart';
import 'package:skilltrack/features/ai_task_generation/view_models/append_task_generation_view_model.dart';
import 'package:skilltrack/features/kanban/models/kanban_status.dart';

import '../kanban/fake_repository.dart';
import '../projects/fake_project_repository.dart';

void main() {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);

  test('existing task request includes only bounded generation context', () {
    final summary = ExistingTaskSummary(
      title: '  Create authentication  ',
      description: '  ${'x' * 501}  ',
      status: 'in_progress',
      deadline: DateTime(2026, 11, 20, 23, 59),
      sortOrder: 2000,
    );
    expect(summary.toRequestJson(), {
      'title': 'Create authentication',
      'description': 'x' * 500,
      'status': 'in_progress',
      'deadline': '2026-11-20',
      'sortOrder': 2000,
    });
    expect(summary.description, '  ${'x' * 501}  ');
    expect(
      const ExistingTaskSummary(
        title: 'No deadline',
        status: 'todo',
        sortOrder: 0,
      ).toRequestJson(),
      {
        'title': 'No deadline',
        'description': '',
        'status': 'todo',
        'deadline': null,
        'sortOrder': 0,
      },
    );
  });

  test('draft copy and revision JSON keep local checklist immutable', () {
    final original = GeneratedTaskDraft(
      title: '  Build login  ',
      description: '  Add authentication  ',
      priority: 'high',
      deadline: DateTime(2026, 11, 20, 23),
      position: 2,
      checklist: ['  Make form  ', 'Connect auth'],
    );
    final edited = original.copyWith(title: 'Test login');
    expect(edited.title, 'Test login');
    expect(edited.description, original.description);
    expect(edited.deadline, original.deadline);
    expect(edited.position, 2);
    expect(() => edited.checklist.add('More'), throwsUnsupportedError);
    expect(original.title, '  Build login  ');
    expect(original.toRevisionJson(), {
      'title': 'Build login',
      'description': 'Add authentication',
      'priority': 'high',
      'deadline': '2026-11-20',
      'position': 2,
      'checklist': ['Make form', 'Connect auth'],
    });
    expect(
      GeneratedTaskDraft.validationError(
        [
          original.copyWith(checklist: ['  Test ', 'test']),
        ],
        startDate: DateTime(2026, 11, 1),
        endDate: DateTime(2026, 11, 30),
      ),
      AppErrorMessages.invalidGeneratedChecklist,
    );
  });

  test('service includes task context only for append generation', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final bodies = <Map<String, dynamic>>[];
    final subscription = server.listen((request) async {
      final body = await utf8.decoder.bind(request).join();
      request.response.headers.contentType = ContentType.json;
      if (request.uri.path == '/auth/v1/token') {
        request.response.write(
          jsonEncode({
            'access_token': 'test-token',
            'token_type': 'bearer',
            'expires_in': 3600,
            'refresh_token': 'test-refresh',
            'user': {
              'id': 'user-1',
              'aud': 'authenticated',
              'role': 'authenticated',
              'email': 'user@example.com',
              'created_at': '2026-10-01T00:00:00Z',
              'app_metadata': <String, Object?>{},
              'user_metadata': <String, Object?>{},
            },
          }),
        );
      } else {
        bodies.add((jsonDecode(body) as Map).cast<String, dynamic>());
        request.response.write('{}');
      }
      await request.response.close();
    });
    final client = SupabaseClient(
      'http://127.0.0.1:${server.port}',
      'test-public-key',
    );
    addTearDown(() async {
      await client.dispose();
      await subscription.cancel();
      await server.close(force: true);
    });
    await client.auth.signInWithPassword(
      email: 'user@example.com',
      password: 'password',
    );
    final service = AiTaskGenerationService(client);
    final task = ExistingTaskSummary(
      title: ' Build login ',
      description: ' Implement authentication ',
      status: 'in_progress',
      deadline: DateTime(2026, 11, 20),
      sortOrder: 2000,
    );
    await service.generateRaw(
      title: 'Project',
      description: 'Description',
      endDate: DateTime(2026, 12, 1),
      mode: TaskGenerationMode.append,
      existingTasks: [task],
    );
    await service.generateRaw(
      title: 'Project',
      description: 'Description',
      endDate: DateTime(2026, 12, 1),
    );
    final draft = GeneratedTaskDraft(
      title: 'Latest edited draft',
      description: 'Updated locally',
      priority: 'high',
      deadline: DateTime(2026, 11, 25),
      position: 0,
      checklist: ['Test it'],
    );
    await service.reviseRaw(
      title: 'Project',
      description: 'Description',
      endDate: DateTime(2026, 12, 1),
      sourceMode: TaskGenerationMode.initial,
      feedback: '  More tests  ',
      currentDraft: [draft],
      existingTasks: [task],
    );
    await service.reviseRaw(
      title: 'Project',
      description: 'Description',
      endDate: DateTime(2026, 12, 1),
      sourceMode: TaskGenerationMode.append,
      feedback: '  Add security checks  ',
      currentDraft: [draft],
      existingTasks: [task],
    );
    expect(bodies, hasLength(4));
    expect(bodies.first, {
      'projectName': 'Project',
      'description': 'Description',
      'deadline': '2026-12-01',
      'generationMode': 'append',
      'existingTasks': [task.toRequestJson()],
    });
    expect(bodies[1], {
      'projectName': 'Project',
      'description': 'Description',
      'deadline': '2026-12-01',
    });
    expect(bodies[2], {
      'projectName': 'Project',
      'description': 'Description',
      'deadline': '2026-12-01',
      'generationMode': 'revise',
      'sourceMode': 'initial',
      'revisionFeedback': 'More tests',
      'existingTasks': [],
      'currentDraft': [draft.toRevisionJson()],
    });
    expect(bodies[3], {
      ...bodies[2],
      'sourceMode': 'append',
      'revisionFeedback': 'Add security checks',
      'existingTasks': [task.toRequestJson()],
    });
    for (final mode in [
      TaskGenerationMode.initial,
      TaskGenerationMode.append,
    ]) {
      await service.generateRaw(
        title: 'Project',
        description: 'Description',
        endDate: DateTime(2026, 12, 1),
        mode: mode,
        existingTasks: [task],
        constraints: '  Flutter only  ',
      );
      expect(bodies.last['constraints'], 'Flutter only');
      if (mode == TaskGenerationMode.append) {
        expect(bodies.last['existingTasks'], [task.toRequestJson()]);
      }
      await service.reviseRaw(
        title: 'Project',
        description: 'Description',
        endDate: DateTime(2026, 12, 1),
        sourceMode: mode,
        feedback: 'Add tests',
        currentDraft: [draft],
        existingTasks: [task],
        constraints: '  Flutter only  ',
      );
      expect(bodies.last['constraints'], 'Flutter only');
      expect(bodies.last['revisionFeedback'], 'Add tests');
    }
    await service.generateRaw(
      title: 'Project',
      description: 'Description',
      endDate: DateTime(2026, 12, 1),
      constraints: '   ',
    );
    expect(bodies.last, isNot(contains('constraints')));
    const milestone = ProjectMilestone(
      id: 'milestone-1',
      projectId: 'project-1',
      title: 'Authentication',
      position: 0,
    );
    final associated = draft.copyWith(
      milestone: GeneratedMilestoneDraft.existing(milestone),
    );
    for (final revise in [false, true]) {
      if (revise) {
        await service.reviseRaw(
          title: 'Project',
          description: 'Description',
          endDate: DateTime(2026, 12, 1),
          sourceMode: TaskGenerationMode.append,
          feedback: 'Add tests',
          currentDraft: [associated],
          projectId: 'project-1',
          existingMilestones: [milestone],
          existingTasks: [task],
        );
      } else {
        await service.generateRaw(
          title: 'Project',
          description: 'Description',
          endDate: DateTime(2026, 12, 1),
          mode: TaskGenerationMode.append,
          projectId: 'project-1',
          existingMilestones: [milestone],
          existingTasks: [task],
        );
      }
      expect(bodies.last['projectId'], 'project-1');
      expect(bodies.last['existingMilestones'], [milestone.toGenerationJson()]);
      if (revise) {
        final sent = (bodies.last['currentDraft'] as List).single as Map;
        expect(sent['milestone'], associated.milestone!.toJson());
        expect(sent['draftTaskId'], associated.localId);
      }
    }
  });

  Future<(FakeProjectRepository, String)> project({DateTime? endDate}) async {
    final projects = FakeProjectRepository();
    final created = await projects.createProject(
      name: 'Learning app',
      description: 'Build a learning app',
      startDate: today.subtract(const Duration(days: 10)),
      endDate: endDate ?? today.add(const Duration(days: 10)),
    );
    return (projects, created.boardId!);
  }

  GeneratedTaskDraft draft(String title, int position) => GeneratedTaskDraft(
    title: title,
    description: 'Implementation task',
    priority: 'medium',
    deadline: today.add(const Duration(days: 2)),
    position: position,
    checklist: ['Plan', 'Implement'],
  );

  test(
    'replacement keeps matching old titles, cancels safely and freezes retry payload',
    () async {
      final (projects, board) = await project();
      final tasks = ReplacementTasks();
      final generator = FakeTaskGenerationRepository()
        ..result = [
          draft('Existing', 0),
          draft('Second', 1),
          draft('Third', 2),
        ];
      final model = AppendTaskGenerationViewModel(
        projectId: projects.stored.single.project.id,
        boardId: board,
        projectRepository: projects,
        taskRepository: tasks,
        generationRepository: generator,
      );
      addTearDown(model.dispose);
      expect(await model.generateMoreTasks(replacementFeedback: '  '), isNull);
      expect(generator.calls, 0);
      generator.fail = true;
      expect(
        await model.generateMoreTasks(replacementFeedback: 'Use smaller steps'),
        isNull,
      );
      expect(tasks.writes, isEmpty);
      generator.fail = false;
      await model.generateMoreTasks(replacementFeedback: 'Use smaller steps');
      expect(generator.lastMode, TaskGenerationMode.replace);
      expect(model.pendingGeneratedTasks.first.title, 'Existing');
      model.cancelGeneratedTaskPreview();
      expect(tasks.writes, isEmpty);
      await model.generateMoreTasks(replacementFeedback: 'Use smaller steps');
      generator.failRevision = true;
      final previous = model.pendingGeneratedTasks;
      expect(await model.reviseGeneratedTasks('More tests'), false);
      expect(model.pendingGeneratedTasks, previous);
      tasks.fail = true;
      expect(await model.confirmGeneratedTasks(), isNull);
      expect(model.canCustomizeGeneratedTasks, false);
      tasks.fail = false;
      expect(await model.confirmGeneratedTasks(), true);
      expect(tasks.writes.length, 2);
      expect(tasks.writes[0], tasks.writes[1]);
      expect(model.pendingGeneratedTasks, isEmpty);
    },
  );

  test(
    'append customization and revision keep saved tasks untouched',
    () async {
      final (projects, board) = await project();
      final saved = sampleTask(
        '1',
        'Existing',
        KanbanStatus.todo,
        order: 5000,
      ).copyWith(boardId: board);
      final tasks = FakeKanbanRepository(tasks: [saved]);
      final generator = FakeTaskGenerationRepository()
        ..result = [draft('First', 0), draft('Second', 1), draft('Third', 2)];
      final model = AppendTaskGenerationViewModel(
        projectId: projects.stored.single.project.id,
        boardId: board,
        projectRepository: projects,
        taskRepository: tasks,
        generationRepository: generator,
      );
      addTearDown(model.dispose);
      expect(await model.generateMoreTasks(), hasLength(3));
      expect(model.updateGeneratedTask(0, draft('Existing!', 0)), isFalse);
      expect(model.updateGeneratedTask(0, draft('  ', 0)), isFalse);
      expect(
        model.updateGeneratedTask(
          0,
          draft(
            'First',
            0,
          ).copyWith(deadline: today.subtract(const Duration(days: 1))),
        ),
        isFalse,
      );
      expect(
        model.updateGeneratedTask(
          0,
          draft('Customized', 0).copyWith(checklist: ['Review', 'Test']),
        ),
        isTrue,
      );
      model.removeGeneratedTask(1);
      expect(model.pendingGeneratedTasks.map((item) => item.position), [0, 1]);
      model.reorderGeneratedTask(0, 2);
      expect(model.pendingGeneratedTasks.map((item) => item.title), [
        'Third',
        'Customized',
      ]);
      expect(model.pendingGeneratedTasks.map((item) => item.position), [0, 1]);
      generator.failRevision = true;
      expect(await model.reviseGeneratedTasks('  More testing  '), isFalse);
      expect(model.pendingGeneratedTasks.map((item) => item.title), [
        'Third',
        'Customized',
      ]);
      generator.failRevision = false;
      generator.revisionResult = [draft('Revised', 0)];
      expect(await model.reviseGeneratedTasks('  More testing  '), isTrue);
      expect(generator.lastSourceMode, TaskGenerationMode.append);
      expect(generator.lastFeedback, 'More testing');
      expect(generator.lastCurrentDraft.map((item) => item.title), [
        'Third',
        'Customized',
      ]);
      expect(generator.lastExistingTasks.single.title, 'Existing');
      expect(tasks.generatedInsertCalls, 0);
      expect(tasks.stored, [saved]);
      expect(
        model.updateGeneratedTask(
          0,
          draft('Final', 0).copyWith(checklist: ['Final check']),
        ),
        isTrue,
      );
      expect(await model.confirmGeneratedTasks(), isTrue);
      expect(generator.calls, 1);
      expect(generator.revisionCalls, 2);
      expect(tasks.stored.first, saved);
      expect(tasks.stored.last.title, 'Final');
      expect(tasks.stored.last.sortOrder, 6000);
      expect(tasks.stored.last.checklistItems.single.title, 'Final check');
    },
  );

  test(
    'append revision blocks repeated requests and keeps current drafts',
    () async {
      final (projects, board) = await project();
      final tasks = FakeKanbanRepository();
      final generator = FakeTaskGenerationRepository()
        ..pendingRevision = Completer<List<GeneratedTaskDraft>>();
      final model = AppendTaskGenerationViewModel(
        projectId: projects.stored.single.project.id,
        boardId: board,
        projectRepository: projects,
        taskRepository: tasks,
        generationRepository: generator,
      );
      addTearDown(model.dispose);
      expect(await model.generateMoreTasks(), isNotNull);
      expect(await model.reviseGeneratedTasks(' '), isFalse);
      expect(await model.reviseGeneratedTasks('x' * 1001), isFalse);
      final first = model.reviseGeneratedTasks('Make it simpler');
      await Future<void>.delayed(Duration.zero);
      expect(model.isRevisingGeneratedTasks, isTrue);
      expect(await model.reviseGeneratedTasks('Again'), isFalse);
      expect(model.updateGeneratedTask(0, draft('Blocked', 0)), isFalse);
      expect(await model.confirmGeneratedTasks(), isNull);
      generator.pendingRevision!.complete([draft('Simpler', 0)]);
      expect(await first, isTrue);
      expect(generator.revisionCalls, 1);
      expect(model.pendingGeneratedTasks.single.title, 'Simpler');
      expect(tasks.generatedInsertCalls, 0);
    },
  );

  test('append parser permits empty, one and two tasks', () {
    List<GeneratedTaskDraft> parse(Object response) =>
        GeneratedTaskDraft.parseTasks(
          response,
          startDate: today,
          endDate: today.add(const Duration(days: 10)),
          minimumTaskCount: 0,
        );
    expect(parse({'milestones': []}), isEmpty);
    final one = parse({
      'milestones': [
        {
          'title': 'More',
          'tasks': [
            {'title': 'Only task'},
          ],
        },
      ],
    });
    expect(one, hasLength(1));
    expect(one.single.deadline, today);
    expect(
      parse({
        'milestones': [
          {
            'title': 'More',
            'tasks': [
              {'title': 'First'},
              {'title': 'Second'},
            ],
          },
        ],
      }),
      hasLength(2),
    );
    expect(
      () => GeneratedTaskDraft.parseTasks(
        {'milestones': []},
        startDate: today,
        endDate: today,
      ),
      throwsA(isA<AppException>()),
    );
  });

  test(
    'generation includes every status and keeps current tasks untouched',
    () async {
      final (projects, board) = await project();
      final existing = FakeKanbanRepository(
        tasks: [
          sampleTask(
            '1',
            'Set up app',
            KanbanStatus.todo,
            order: 1000,
          ).copyWith(boardId: board),
          sampleTask(
            '2',
            'Build login',
            KanbanStatus.inProgress,
          ).copyWith(boardId: board),
          sampleTask(
            '3',
            'Write tests',
            KanbanStatus.completed,
          ).copyWith(boardId: board),
          sampleTask(
            '4',
            'Old idea',
            KanbanStatus.todo,
          ).copyWith(boardId: board, isArchived: true),
        ],
      );
      final generator = FakeTaskGenerationRepository()
        ..result = [draft('Set up app.', 0), draft('New feature', 1)];
      final model = AppendTaskGenerationViewModel(
        projectId: projects.stored.single.project.id,
        boardId: board,
        projectRepository: projects,
        taskRepository: existing,
        generationRepository: generator,
      );
      addTearDown(model.dispose);
      expect(await model.generateMoreTasks(), hasLength(1));
      expect(model.pendingGeneratedTasks.single.title, 'New feature');
      expect(generator.lastMode, TaskGenerationMode.append);
      expect(generator.lastExistingTasks.map((item) => item.status), [
        'todo',
        'in_progress',
        'completed',
        'archived',
      ]);
      expect(
        generator.lastExistingTasks.first.description,
        'Description for Set up app',
      );
      expect(
        generator.lastExistingTasks.first.deadline,
        DateTime(2026, 10, 15),
      );
      expect(generator.lastExistingTasks.first.sortOrder, 1000);
      expect(generator.lastStartDate, today);
      expect(generator.lastEndDate, today.add(const Duration(days: 10)));
      expect(existing.stored, hasLength(4));
      expect(existing.generatedInsertCalls, 0);
    },
  );

  test('append request includes at most 100 existing summaries', () async {
    final (projects, board) = await project();
    final tasks = FakeKanbanRepository(
      tasks: [
        for (var index = 0; index < 101; index++)
          sampleTask(
            '$index',
            'Existing $index',
            KanbanStatus.todo,
          ).copyWith(boardId: board),
      ],
    );
    final generator = FakeTaskGenerationRepository();
    final model = AppendTaskGenerationViewModel(
      projectId: projects.stored.single.project.id,
      boardId: board,
      projectRepository: projects,
      taskRepository: tasks,
      generationRepository: generator,
    );
    addTearDown(model.dispose);
    expect(await model.generateMoreTasks(), isNotNull);
    expect(generator.calls, 1);
    expect(tasks.summaryCalls, 1);
    expect(generator.lastExistingTasks, hasLength(100));
    expect(
      generator.lastExistingTasks.first.description,
      'Description for Existing 0',
    );
    expect(generator.lastExistingTasks.last.title, 'Existing 99');
  });

  test(
    'Cancel clears drafts without inserts and expired project blocks AI',
    () async {
      final (projects, board) = await project();
      final tasks = FakeKanbanRepository();
      final generator = FakeTaskGenerationRepository();
      final model = AppendTaskGenerationViewModel(
        projectId: projects.stored.single.project.id,
        boardId: board,
        projectRepository: projects,
        taskRepository: tasks,
        generationRepository: generator,
      );
      addTearDown(model.dispose);
      expect(await model.generateMoreTasks(), hasLength(3));
      model.cancelGeneratedTaskPreview();
      expect(model.pendingGeneratedTasks, isEmpty);
      expect(tasks.generatedInsertCalls, 0);
      expect(projects.stored, hasLength(1));

      final (expired, expiredBoard) = await project(
        endDate: today.subtract(const Duration(days: 1)),
      );
      final expiredModel = AppendTaskGenerationViewModel(
        projectId: expired.stored.single.project.id,
        boardId: expiredBoard,
        projectRepository: expired,
        taskRepository: tasks,
        generationRepository: generator,
      );
      addTearDown(expiredModel.dispose);
      expect(await expiredModel.generateMoreTasks(), isNull);
      expect(
        expiredModel.errorMessage,
        AppErrorMessages.expiredProjectDeadline,
      );
      expect(generator.calls, 1);
    },
  );

  test(
    'empty suggestions show a message and repeated Generate starts once',
    () async {
      final (projects, board) = await project();
      final tasks = FakeKanbanRepository();
      final generator = FakeTaskGenerationRepository()
        ..pending = Completer<List<GeneratedTaskDraft>>();
      final model = AppendTaskGenerationViewModel(
        projectId: projects.stored.single.project.id,
        boardId: board,
        projectRepository: projects,
        taskRepository: tasks,
        generationRepository: generator,
      );
      addTearDown(model.dispose);
      final first = model.generateMoreTasks();
      expect(model.isGeneratingTasks, isTrue);
      expect(await model.generateMoreTasks(), isNull);
      generator.pending!.complete([]);
      expect(await first, isNull);
      expect(model.errorMessage, AppErrorMessages.noAdditionalTasks);
      expect(model.isGeneratingTasks, isFalse);
      expect(generator.calls, 1);
      expect(tasks.generatedInsertCalls, 0);
    },
  );

  test(
    'Confirm rechecks titles, appends after To-Do and saves checklists once',
    () async {
      final (projects, board) = await project();
      final tasks = FakeKanbanRepository(
        tasks: [
          sampleTask(
            '1',
            'Existing',
            KanbanStatus.todo,
            order: 5000,
          ).copyWith(boardId: board),
        ],
      );
      final generator = FakeTaskGenerationRepository()
        ..result = [draft('Added manually', 0), draft('Fresh task', 1)];
      final model = AppendTaskGenerationViewModel(
        projectId: projects.stored.single.project.id,
        boardId: board,
        projectRepository: projects,
        taskRepository: tasks,
        generationRepository: generator,
      );
      addTearDown(model.dispose);
      expect(await model.generateMoreTasks(), hasLength(2));
      tasks.stored.add(
        sampleTask(
          '2',
          'Added manually.',
          KanbanStatus.todo,
          order: 5500,
        ).copyWith(boardId: board),
      );
      final first = model.confirmGeneratedTasks();
      expect(await model.confirmGeneratedTasks(), isNull);
      expect(await first, isTrue);
      expect(projects.stored, hasLength(1));
      expect(generator.calls, 1);
      expect(tasks.generatedInsertCalls, 1);
      expect(tasks.stored.last.title, 'Fresh task');
      expect(tasks.stored.last.sortOrder, 6500);
      expect(tasks.stored.last.checklistItems.map((item) => item.title), [
        'Plan',
        'Implement',
      ]);
      expect(tasks.stored.first.sortOrder, 5000);
    },
  );

  test('Confirm skips insert when all drafts became duplicates', () async {
    final (projects, board) = await project();
    final tasks = FakeKanbanRepository();
    final generator = FakeTaskGenerationRepository()
      ..result = [draft('Fresh task', 0)];
    final model = AppendTaskGenerationViewModel(
      projectId: projects.stored.single.project.id,
      boardId: board,
      projectRepository: projects,
      taskRepository: tasks,
      generationRepository: generator,
    );
    addTearDown(model.dispose);
    expect(await model.generateMoreTasks(), hasLength(1));
    tasks.stored.add(
      sampleTask(
        '1',
        'Fresh task!',
        KanbanStatus.completed,
      ).copyWith(boardId: board),
    );
    expect(await model.confirmGeneratedTasks(), isTrue);
    expect(tasks.generatedInsertCalls, 0);
    expect(model.feedbackMessage, AppErrorMessages.additionalTasksAlreadyExist);
  });
  test(
    'append retries a lost response with the same ID and frozen draft',
    () async {
      final (projects, board) = await project();
      final tasks = FakeKanbanRepository()..loseGeneratedResponseOnce = true;
      final generator = FakeTaskGenerationRepository()
        ..result = [draft('Added elsewhere', 0), draft('Extra', 1)];
      final model = AppendTaskGenerationViewModel(
        projectId: projects.stored.single.project.id,
        boardId: board,
        projectRepository: projects,
        taskRepository: tasks,
        generationRepository: generator,
      );
      addTearDown(model.dispose);
      await model.generateMoreTasks();
      tasks.stored.add(
        sampleTask(
          'other',
          'Added elsewhere',
          KanbanStatus.todo,
        ).copyWith(boardId: board),
      );
      expect(await model.confirmGeneratedTasks(), isNull);
      expect(tasks.stored.where((task) => task.title == 'Extra'), hasLength(1));
      expect(model.canCustomizeGeneratedTasks, isFalse);
      expect(model.updateGeneratedTask(0, draft('Changed', 0)), isFalse);
      expect(await model.confirmGeneratedTasks(), isTrue);
      expect(tasks.stored.where((task) => task.title == 'Extra'), hasLength(1));
      expect(tasks.generatedRequestIds.toSet(), hasLength(1));
      expect(tasks.generatedInsertCalls, 2);
    },
  );

  test('parser preserves revised dates and falls back for invalid dates', () {
    final parsed = GeneratedTaskDraft.parseTasks(
      {
        'milestones': [
          {
            'tasks': [
              {'title': 'Preserved', 'deadline': '2026-11-23'},
              {'title': 'Invalid', 'deadline': '2026-02-30'},
              {'title': 'Outside', 'deadline': '2027-01-01'},
            ],
          },
        ],
      },
      startDate: DateTime(2026, 11, 1),
      endDate: DateTime(2026, 11, 30),
    );
    expect(parsed.first.deadline, DateTime(2026, 11, 23));
    expect(parsed[1].deadline, DateTime(2026, 11, 16));
    expect(parsed.last.deadline, DateTime(2026, 11, 30));
  });
  test('revision without a returned date retains the customized deadline', () {
    final date = DateTime(2026, 11, 23);
    final parsed = GeneratedTaskDraft.parseTasks(
      {
        'milestones': [
          {
            'tasks': [
              {'title': 'Build'},
            ],
          },
        ],
      },
      startDate: DateTime(2026, 11, 1),
      endDate: DateTime(2026, 11, 30),
      minimumTaskCount: 1,
      preservedDeadlines: {normalizedTaskTitle('Build'): date},
    );
    expect(parsed.single.deadline, date);
  });
}

class ReplacementTasks extends FakeKanbanRepository
    implements TaskListReplacementRepository {
  bool fail = false;
  final writes = <String>[];
  @override
  Future<Map<String, dynamic>> replacementContext(String boardId) async => {
    'version': 'snapshot',
    'count': 2,
  };
  @override
  Future<void> replaceGeneratedTasks(
    String boardId,
    List<GeneratedTaskDraft> tasks, {
    required String requestId,
    required String expectedVersion,
  }) async {
    writes.add(
      jsonEncode([
        requestId,
        expectedVersion,
        tasks.map((t) => t.toRevisionJson()).toList(),
      ]),
    );
    if (fail) throw StateError('lost response');
  }
}
