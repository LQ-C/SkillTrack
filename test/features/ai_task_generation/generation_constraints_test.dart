import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skilltrack/core/errors/app_exception.dart';
import 'package:skilltrack/features/ai_task_generation/models/generated_task_draft.dart';
import 'package:skilltrack/features/ai_task_generation/view_models/append_task_generation_view_model.dart';
import 'package:skilltrack/features/ai_task_generation/widgets/task_generation_constraints_field.dart';
import 'package:skilltrack/features/projects/viewmodels/create_project_view_model.dart';

import '../kanban/fake_repository.dart';
import '../projects/fake_project_repository.dart';

void main() {
  final today = DateUtils.dateOnly(DateTime.now());

  CreateProjectViewModel initial(
    FakeTaskGenerationRepository generator, {
    FakeProjectRepository? projects,
  }) {
    final model = CreateProjectViewModel(
      projects ?? FakeProjectRepository(),
      generationRepository: generator,
      taskRepository: FakeKanbanRepository(),
    );
    model.setStartDate(today);
    model.setEndDate(today.add(const Duration(days: 10)));
    addTearDown(model.dispose);
    return model;
  }

  Future<AppendTaskGenerationViewModel> append(
    FakeTaskGenerationRepository generator,
  ) async {
    final projects = FakeProjectRepository();
    final project = await projects.createProject(
      name: 'App',
      description: 'Build an app',
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
    'empty project creation remains independent of generation constraints',
    () async {
      final generator = FakeTaskGenerationRepository();
      final projects = FakeProjectRepository();
      final model = initial(generator, projects: projects);
      await model.generateTaskPreview(
        name: 'App',
        description: 'Build it',
        constraints: 'x' * 1001,
      );
      expect(
        await model.submit(name: 'App', description: 'Original description'),
        isNotNull,
      );
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
    'confirmed project stores only original description, not generation constraints',
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
}
