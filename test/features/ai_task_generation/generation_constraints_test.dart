import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skilltrack/core/errors/app_exception.dart';
import 'package:skilltrack/features/ai_task_generation/models/generated_task_draft.dart';
import 'package:skilltrack/features/ai_task_generation/view_models/append_task_generation_view_model.dart';
import 'package:skilltrack/features/ai_task_generation/widgets/task_generation_constraints_field.dart';
import 'package:skilltrack/features/projects/viewmodels/create_project_view_model.dart';
import 'package:skilltrack/features/projects/models/learning_project.dart';

import '../kanban/fake_repository.dart';
import '../projects/fake_project_repository.dart';

void main() {
  final today = DateUtils.dateOnly(DateTime.now());

  CreateProjectViewModel initial(
    FakeTaskGenerationRepository generator, {
    FakeProjectRepository? projects,
    FakeKanbanRepository? tasks,
  }) {
    final model = CreateProjectViewModel(
      (projects ?? FakeProjectRepository())
        ..generatedTaskRepository = tasks ?? FakeKanbanRepository(),
      generationRepository: generator,
    );
    model.setStartDate(today);
    model.setEndDate(today.add(const Duration(days: 10)));
    addTearDown(model.dispose);
    return model;
  }

  Future<AppendTaskGenerationViewModel> append(
    FakeTaskGenerationRepository generator, {
    FakeProjectRepository? projects,
    String? savedConstraints,
  }) async {
    projects ??= FakeProjectRepository();
    final project = await projects.createProject(
      name: 'App',
      description: 'Build an app',
      constraints: savedConstraints,
      startDate: today,
      endDate: today.add(const Duration(days: 10)),
    );
    final model = AppendTaskGenerationViewModel(
      projectId: project.project.id,
      boardId: project.boardId!,
      projectRepository: projects,
      taskRepository: FakeKanbanRepository(),
      generationRepository: generator,
    );
    addTearDown(model.dispose);
    return model;
  }

  test(
    'initial generation accepts empty constraints and trims nonempty input',
    () async {
      final generator = FakeTaskGenerationRepository();
      final model = initial(generator);
      expect(
        await model.generateTaskPreview(name: 'App', description: 'Build it'),
        isNotNull,
      );
      expect(generator.lastConstraints, '');
      model.cancelGeneratedTaskPreview();
      expect(
        await model.generateTaskPreview(
          name: 'App',
          description: 'Build it',
          constraints: '  Flutter only  ',
        ),
        isNotNull,
      );
      expect(generator.lastConstraints, 'Flutter only');
    },
  );

  test(
    'both ViewModels reject oversized constraints before invoking generation',
    () async {
      final generator = FakeTaskGenerationRepository();
      final model = initial(generator);
      expect(
        await model.generateTaskPreview(
          name: 'App',
          description: 'Build it',
          constraints: 'x' * 1001,
        ),
        isNull,
      );
      expect(model.errorMessage, AppErrorMessages.invalidGenerationConstraints);
      final more = await append(generator);
      expect(await more.generateMoreTasks(constraints: 'x' * 1001), isNull);
      expect(more.errorMessage, AppErrorMessages.invalidGenerationConstraints);
      expect(generator.calls, 0);
    },
  );

  test(
    'empty project creation stores constraints separately without invoking AI',
    () async {
      final generator = FakeTaskGenerationRepository();
      final projects = FakeProjectRepository();
      final model = initial(generator, projects: projects);
      expect(
        await model.submit(
          name: 'App',
          description: 'Original description',
          constraints: '  Flutter only  ',
        ),
        isNotNull,
      );
      expect(projects.stored.single.project.constraints, 'Flutter only');
      expect(
        projects.stored.single.project.description,
        'Original description',
      );
      expect(generator.calls, 0);
    },
  );

  test(
    'initial revision retains original constraints until cancellation',
    () async {
      final generator = FakeTaskGenerationRepository();
      final model = initial(generator);
      await model.generateTaskPreview(
        name: 'App',
        description: 'Build it',
        constraints: ' Flutter only ',
      );
      expect(await model.reviseGeneratedTasks('Add tests'), isTrue);
      expect(generator.lastRevisionConstraints, 'Flutter only');
      expect(generator.lastFeedback, 'Add tests');
      model.cancelGeneratedTaskPreview();
      await model.generateTaskPreview(name: 'App', description: 'Build it');
      await model.reviseGeneratedTasks('Include documentation');
      expect(generator.lastRevisionConstraints, '');
    },
  );

  test(
    'append generation and revision retain constraints without mixing feedback',
    () async {
      final generator = FakeTaskGenerationRepository();
      final model = await append(generator);
      expect(
        await model.generateMoreTasks(constraints: '  Include testing  '),
        isNotNull,
      );
      expect(generator.lastConstraints, 'Include testing');
      expect(await model.reviseGeneratedTasks('Add unit tests'), isTrue);
      expect(generator.lastRevisionConstraints, 'Include testing');
      expect(generator.lastFeedback, 'Add unit tests');
      model.cancelGeneratedTaskPreview();
      await model.generateMoreTasks();
      await model.reviseGeneratedTasks('Add docs');
      expect(generator.lastConstraints, '');
      expect(generator.lastRevisionConstraints, '');
    },
  );

  test(
    'generation failures do not retain constraints for the next preview',
    () async {
      final generator = FakeTaskGenerationRepository()..fail = true;
      final model = initial(generator);
      expect(
        await model.generateTaskPreview(
          name: 'App',
          description: 'Build it',
          constraints: 'Old constraints',
        ),
        isNull,
      );
      generator.fail = false;
      await model.generateTaskPreview(name: 'App', description: 'Build it');
      await model.reviseGeneratedTasks('Add tests');
      expect(generator.lastRevisionConstraints, '');
    },
  );

  test(
    'duplicate initial generation keeps the first request constraints',
    () async {
      final generator = FakeTaskGenerationRepository()
        ..pending = Completer<List<GeneratedTaskDraft>>();
      final model = initial(generator);
      final pending = model.generateTaskPreview(
        name: 'App',
        description: 'Build it',
        constraints: 'First',
      );
      expect(
        await model.generateTaskPreview(
          name: 'App',
          description: 'Build it',
          constraints: 'Second',
        ),
        isNull,
      );
      expect(generator.calls, 1);
      expect(generator.lastConstraints, 'First');
      generator.pending!.complete([
        GeneratedTaskDraft(
          title: 'Task',
          description: 'Build',
          priority: 'medium',
          deadline: today,
          position: 0,
        ),
      ]);
      await pending;
    },
  );

  test(
    'confirmed project saves the preview constraints separately from the description',
    () async {
      final generator = FakeTaskGenerationRepository();
      final projects = FakeProjectRepository();
      final model = initial(generator, projects: projects);
      await model.generateTaskPreview(
        name: 'App',
        description: 'Build it',
        constraints: 'Flutter only',
      );
      expect(await model.confirmGeneratedTasks(), isNotNull);
      expect(projects.stored.single.project.description, 'Build it');
      expect(projects.stored.single.project.name, 'App');
      expect(projects.stored.single.project.constraints, 'Flutter only');
    },
  );

  testWidgets(
    'constraints field has a stable key and specified optional presentation',
    (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TaskGenerationConstraintsField(
              controller: controller,
              readOnly: true,
            ),
          ),
        ),
      );
      final field = tester.widget<TextField>(
        find.byKey(const Key('task-generation-constraints-field')),
      );
      expect(field.maxLength, 1000);
      expect(field.minLines, 2);
      expect(field.maxLines, 4);
      expect(field.readOnly, isTrue);
      expect(
        field.decoration!.labelText,
        'Task generation constraints (optional)',
      );
    },
  );
  test(
    'project constraints parse saved, null and legacy missing values and serialize normalized text',
    () {
      const base = {
        'id': 'project-1',
        'owner_id': 'user-1',
        'name': 'App',
        'status': 'active',
      };
      for (final value in [null, '', '  ', ' Flutter only ']) {
        final project = LearningProject.fromMap({
          ...base,
          'constraints_text': value,
        });
        expect(
          project.constraints,
          value == ' Flutter only ' ? 'Flutter only' : null,
        );
        expect(project.toMap()['constraints_text'], project.constraints);
      }
      expect(LearningProject.fromMap(base).constraints, isNull);
      const project = LearningProject(
        id: 'p',
        ownerId: 'u',
        name: 'App',
        status: 'active',
        constraints: '  Saved  ',
      );
      expect(project.toMap()['constraints_text'], 'Saved');
      expect(project.copyWith(name: 'Renamed').constraints, 'Saved');
      expect(project.copyWith(constraints: ' New ').constraints, 'New');
      expect(project.copyWith(clearConstraints: true).constraints, isNull);
      expect(project.copyWith(constraints: '  ').constraints, isNull);
    },
  );

  test(
    'create and edit enforce length limit and preserve or explicitly clear saved constraints',
    () async {
      final projects = FakeProjectRepository();
      final model = initial(FakeTaskGenerationRepository(), projects: projects);
      expect(
        await model.submit(
          name: 'App',
          description: 'Build',
          constraints: 'x' * 1001,
        ),
        isNull,
      );
      expect(model.errorMessage, AppErrorMessages.invalidGenerationConstraints);
      expect(projects.stored, isEmpty);
      final created = await model.submit(
        name: 'App',
        description: 'Build',
        constraints: 'x' * 1000,
      );
      expect(created!.project.constraints, hasLength(1000));
      final editing = CreateProjectViewModel(
        projects,
        original: created.project,
      );
      addTearDown(editing.dispose);
      expect(
        await editing.submit(
          name: 'App',
          description: 'Build',
          constraints: 'x' * 1001,
        ),
        isNull,
      );
      expect(projects.stored.single.project.constraints, hasLength(1000));
      expect(
        await editing.submit(
          name: 'App',
          description: 'Build',
          constraints: '  Updated  ',
        ),
        isNotNull,
      );
      expect(projects.stored.single.project.constraints, 'Updated');
      final compatible = CreateProjectViewModel(
        projects,
        original: projects.stored.single.project,
      );
      addTearDown(compatible.dispose);
      expect(
        await compatible.submit(name: 'Renamed', description: 'Build'),
        isNotNull,
      );
      expect(projects.stored.single.project.constraints, 'Updated');
      expect(
        await compatible.submit(
          name: 'Renamed',
          description: 'Build',
          constraints: '  ',
        ),
        isNotNull,
      );
      expect(projects.stored.single.project.constraints, isNull);
    },
  );

  test(
    'AI confirmation and retries save the same constraints used in preview revisions',
    () async {
      final projects = FakeProjectRepository()..failBoardCreation = true;
      final tasks = FakeKanbanRepository();
      final ai = FakeTaskGenerationRepository();
      final model = initial(ai, projects: projects, tasks: tasks);
      await model.generateTaskPreview(
        name: 'App',
        description: 'Build',
        constraints: '  Original rules  ',
      );
      expect(projects.stored, isEmpty);
      ai.failRevision = true;
      expect(await model.reviseGeneratedTasks('Add tests'), isFalse);
      expect(ai.lastRevisionConstraints, 'Original rules');
      ai.failRevision = false;
      expect(await model.reviseGeneratedTasks('Add tests'), isTrue);
      expect(await model.confirmGeneratedTasks(), isNull);
      projects.failBoardCreation = false;
      tasks.failGeneratedInsert = true;
      expect(await model.confirmGeneratedTasks(), isNull);
      expect(projects.stored, isEmpty);
      tasks.failGeneratedInsert = false;
      expect(await model.confirmGeneratedTasks(), isNotNull);
      expect(projects.stored, hasLength(1));
      expect(projects.stored.single.project.constraints, ai.lastConstraints);
      expect(tasks.generatedRequestIds.toSet(), hasLength(1));
    },
  );

  test(
    'append defaults to saved constraints and keeps preview constraints when the project changes',
    () async {
      final projects = FakeProjectRepository();
      final ai = FakeTaskGenerationRepository();
      final model = await append(
        ai,
        projects: projects,
        savedConstraints: 'Saved rules',
      );
      expect(await model.loadGenerationConstraints(), 'Saved rules');
      await model.generateMoreTasks();
      expect(ai.lastConstraints, 'Saved rules');
      await projects.updateProject(
        projects.stored.single.project.copyWith(constraints: 'New saved rules'),
      );
      expect(await model.loadGenerationConstraints(), 'Saved rules');
      expect(await model.reviseGeneratedTasks('Add tests'), isTrue);
      expect(ai.lastRevisionConstraints, 'Saved rules');
      model.cancelGeneratedTaskPreview();
      expect(await model.loadGenerationConstraints(), 'New saved rules');
    },
  );

  for (final request in ['', '  Current request rules  ']) {
    test(
      'append request override "$request" is retained through failures without changing saved constraints',
      () async {
        final projects = FakeProjectRepository();
        final ai = FakeTaskGenerationRepository();
        final model = await append(
          ai,
          projects: projects,
          savedConstraints: 'Saved rules',
        );
        await model.generateMoreTasks(constraints: request);
        expect(ai.lastConstraints, request.trim());
        final previous = model.pendingGeneratedTasks.first;
        ai.failRevision = true;
        expect(await model.reviseGeneratedTasks('Add tests'), isFalse);
        expect(model.pendingGeneratedTasks.first, same(previous));
        expect(ai.lastRevisionConstraints, request.trim());
        ai.failRevision = false;
        expect(await model.reviseGeneratedTasks('Add tests'), isTrue);
        expect(ai.lastRevisionConstraints, request.trim());
        expect(await model.confirmGeneratedTasks(), isTrue);
        expect(projects.stored.single.project.constraints, 'Saved rules');
      },
    );
  }

  test(
    'legacy projects use empty append constraints and invalid saved limits block generation',
    () async {
      final ai = FakeTaskGenerationRepository();
      final model = await append(ai);
      expect(await model.loadGenerationConstraints(), '');
      await model.generateMoreTasks();
      expect(ai.lastConstraints, '');
      final invalidAi = FakeTaskGenerationRepository();
      final invalid = await append(invalidAi, savedConstraints: 'x' * 1001);
      expect(await invalid.generateMoreTasks(), isNull);
      expect(
        invalid.errorMessage,
        AppErrorMessages.invalidGenerationConstraints,
      );
      expect(invalidAi.calls, 0);
    },
  );
}
