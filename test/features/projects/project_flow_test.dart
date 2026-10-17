import 'dart:async';
import 'dart:ui' show SemanticsAction;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skilltrack/app/app_theme.dart';
import 'package:skilltrack/app/skill_track_app.dart';
import 'package:skilltrack/app/router/app_router.dart';
import 'package:skilltrack/features/kanban/models/kanban_status.dart';
import 'package:skilltrack/features/ai_task_generation/models/generated_task_draft.dart';
import 'package:skilltrack/features/ai_task_generation/views/generated_task_preview_screen.dart';
import 'package:skilltrack/features/projects/views/create_project_screen.dart';
import 'package:skilltrack/features/ai_task_generation/repositories/ai_task_generation_repository.dart';

import '../kanban/fake_repository.dart';
import 'fake_project_repository.dart';

void main() {
  Future<void> showApp(
    WidgetTester tester,
    FakeProjectRepository projects, {
    FakeKanbanRepository? kanban,
    TaskGenerationRepository? generation,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      SkillTrackApp(
        projectRepository: projects,
        kanbanRepository: kanban ?? FakeKanbanRepository(),
        taskGenerationRepository: generation,
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> selectPickerDate(WidgetTester tester, DateTime date) async {
    final dialog = find.byType(DatePickerDialog);
    final labels = MaterialLocalizations.of(tester.element(dialog));
    await tester.tap(find.byTooltip(labels.inputDateModeButtonLabel));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(of: dialog, matching: find.byType(TextField)),
      labels.formatCompactDate(date),
    );
    await tester.tap(find.text(labels.okButtonLabel));
    await tester.pumpAndSettle();
    expect(dialog, findsNothing);
  }

  Future<void> showProjectAction(
    WidgetTester tester,
    String key, {
    double scroll = 120,
  }) async {
    await tester.scrollUntilVisible(
      find.byKey(Key(key)),
      scroll,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
  }

  Future<void> enterValidProjectForm(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('new-project-button')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('project-name-field')),
      'Flutter study',
    );
    await tester.enterText(
      find.byKey(const Key('project-description-field')),
      'Practice widgets',
    );
    final today = DateUtils.dateOnly(DateTime.now());
    for (final (key, date) in [
      ('project-start-date-field', today),
      ('project-end-date-field', today.add(const Duration(days: 7))),
    ]) {
      final field = find.byKey(Key(key));
      await tester.ensureVisible(field);
      await tester.tap(field);
      await tester.pumpAndSettle();
      await selectPickerDate(tester, date);
    }
    await showProjectAction(tester, 'generate-tasks-button');
  }

  testWidgets(
    'Generate previews drafts, then Confirm creates the project and board',
    (tester) async {
      final projects = FakeProjectRepository();
      final kanban = FakeKanbanRepository();
      final generation = FakeTaskGenerationRepository()
        ..result = [
          GeneratedTaskDraft(
            title: 'Build widget',
            description: 'Practice layouts',
            priority: 'high',
            deadline: DateUtils.dateOnly(DateTime.now()),
            position: 0,
            checklist: ['Create screen', 'Run tests'],
          ),
          GeneratedTaskDraft(
            title: 'Review result',
            description: '',
            priority: 'medium',
            deadline: DateUtils.dateOnly(DateTime.now()),
            position: 1,
          ),
        ];
      await showApp(tester, projects, kanban: kanban, generation: generation);
      await tester.tap(find.byKey(const Key('new-project-button')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('project-name-field')),
        'Flutter study',
      );
      await tester.enterText(
        find.byKey(const Key('project-description-field')),
        'Practice widgets',
      );
      final today = DateUtils.dateOnly(DateTime.now());
      final start = find.byKey(const Key('project-start-date-field'));
      await tester.ensureVisible(start);
      await tester.tap(start);
      await tester.pumpAndSettle();
      await selectPickerDate(tester, today);
      final end = find.byKey(const Key('project-end-date-field'));
      await tester.ensureVisible(end);
      await tester.tap(end);
      await tester.pumpAndSettle();
      await selectPickerDate(tester, today.add(const Duration(days: 7)));

      await showProjectAction(tester, 'generate-tasks-button');
      final create = find.byKey(const Key('save-project-button'));
      final generate = find.byKey(const Key('generate-tasks-button'));
      expect(find.text('Create Empty Project'), findsOneWidget);
      expect(find.text('OR'), findsOneWidget);
      expect(find.text('Generate Tasks'), findsOneWidget);
      expect(tester.widget(generate), isA<OutlinedButton>());
      expect(tester.getSize(create).width, tester.getSize(generate).width);
      expect(
        tester.getRect(create).bottom,
        lessThan(tester.getRect(generate).top),
      );
      await tester.tap(generate);
      await tester.pumpAndSettle();
      expect(generation.calls, 1);
      expect(find.byType(GeneratedTaskPreviewScreen), findsOneWidget);
      expect(find.text('2 generated tasks'), findsOneWidget);
      expect(find.text('Build widget'), findsOneWidget);
      expect(find.text('Practice layouts'), findsOneWidget);
      expect(find.text('High'), findsOneWidget);
      expect(find.text('Checklist (2)'), findsOneWidget);
      expect(find.text('Create screen'), findsOneWidget);
      expect(find.text('Run tests'), findsOneWidget);
      expect(find.text('No checklist generated'), findsOneWidget);
      expect(projects.stored, isEmpty);
      expect(kanban.generatedInsertCalls, 0);
      await tester.tap(find.byKey(const Key('confirm-generated-tasks-button')));
      await tester.pumpAndSettle();
      expect(projects.stored.length, 1);
      expect(kanban.generatedInsertCalls, 1);
      expect(kanban.stored.length, 2);
      expect(kanban.stored.first.checklistItems.map((item) => item.title), [
        'Create screen',
        'Run tests',
      ]);
      expect(generation.calls, 1);
      expect(
        kanban.stored.every((task) => task.status == KanbanStatus.todo),
        isTrue,
      );
      expect(find.text('Flutter study'), findsWidgets);
    },
  );

  testWidgets('Cancel and system Back discard drafts but keep the form', (
    tester,
  ) async {
    final projects = FakeProjectRepository();
    final kanban = FakeKanbanRepository();
    final generation = FakeTaskGenerationRepository();
    await showApp(tester, projects, kanban: kanban, generation: generation);
    await enterValidProjectForm(tester);
    for (final useSystemBack in [false, true]) {
      await tester.tap(find.byKey(const Key('generate-tasks-button')));
      await tester.pumpAndSettle();
      expect(find.byType(GeneratedTaskPreviewScreen), findsOneWidget);
      if (useSystemBack) {
        await tester.binding.handlePopRoute();
      } else {
        await tester.tap(
          find.byKey(const Key('cancel-generated-tasks-button')),
        );
      }
      await tester.pumpAndSettle();
      expect(find.byType(GeneratedTaskPreviewScreen), findsNothing);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('project-name-field')))
            .controller!
            .text,
        'Flutter study',
      );
      expect(
        tester
            .widget<TextField>(
              find.byKey(const Key('project-description-field')),
            )
            .controller!
            .text,
        'Practice widgets',
      );
      expect(projects.stored, isEmpty);
      expect(kanban.generatedInsertCalls, 0);
      await showProjectAction(tester, 'generate-tasks-button');
    }
    expect(generation.calls, 2);
  });

  testWidgets('loading blocks duplicate generation and project creation', (
    tester,
  ) async {
    final projects = FakeProjectRepository();
    final generation = FakeTaskGenerationRepository()
      ..pending = Completer<List<GeneratedTaskDraft>>();
    await showApp(tester, projects, generation: generation);
    await enterValidProjectForm(tester);
    final generate = find.byKey(const Key('generate-tasks-button'));
    await tester.tap(generate);
    await tester.pump();
    expect(find.text('Generating your task plan'), findsOneWidget);
    expect(tester.widget<OutlinedButton>(generate).onPressed, isNull);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('save-project-button')))
          .onPressed,
      isNull,
    );
    expect(generation.calls, 1);
    expect(projects.stored, isEmpty);
    generation.pending!.complete([
      GeneratedTaskDraft(
        title: 'First step',
        description: '',
        priority: 'medium',
        deadline: DateUtils.dateOnly(DateTime.now()),
        position: 0,
      ),
    ]);
    await tester.pumpAndSettle();
    expect(find.byType(GeneratedTaskPreviewScreen), findsOneWidget);
    expect(generation.calls, 1);
  });

  testWidgets('failed Confirm retains the preview and allows retry', (
    tester,
  ) async {
    final projects = FakeProjectRepository()..failBoardCreation = true;
    final generation = FakeTaskGenerationRepository();
    await showApp(tester, projects, generation: generation);
    await enterValidProjectForm(tester);
    await tester.tap(find.byKey(const Key('generate-tasks-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-generated-tasks-button')));
    await tester.pumpAndSettle();
    expect(find.byType(GeneratedTaskPreviewScreen), findsOneWidget);
    expect(find.text('Step 1'), findsOneWidget);
    expect(
      find.text('Unable to create the project. Please try again.'),
      findsOneWidget,
    );
    expect(projects.stored, isEmpty);
    projects.failBoardCreation = false;
    await tester.tap(find.byKey(const Key('confirm-generated-tasks-button')));
    await tester.pumpAndSettle();
    expect(projects.stored, hasLength(1));
    expect(generation.calls, 1);
  });

  testWidgets('create actions remain reachable with keyboard and form errors', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 600);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    final projects = FakeProjectRepository();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: CreateProjectScreen(repository: projects),
      ),
    );
    await tester.pumpAndSettle();
    await showProjectAction(tester, 'project-name-field');
    await tester.showKeyboard(find.byKey(const Key('project-name-field')));
    await showProjectAction(tester, 'save-project-button');
    await tester.tap(find.byKey(const Key('save-project-button')));
    await tester.pumpAndSettle();
    await showProjectAction(tester, 'project-name-field', scroll: -120);
    expect(find.text('Project name is required.'), findsOneWidget);
    await showProjectAction(tester, 'generate-tasks-button');
    await tester.tap(find.byKey(const Key('generate-tasks-button')));
    await tester.pump();
    await showProjectAction(tester, 'project-name-field', scroll: -120);
    expect(find.text('Project name is required.'), findsOneWidget);
    expect(projects.stored, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('calendar, label, value and empty space open the date picker', (
    tester,
  ) async {
    await showApp(tester, FakeProjectRepository());
    await tester.tap(find.byKey(const Key('new-project-button')));
    await tester.pumpAndSettle();
    final field = find.byKey(const Key('project-start-date-field'));
    await tester.ensureVisible(field);
    final targets = [
      find.descendant(
        of: field,
        matching: find.byIcon(Icons.calendar_today_outlined),
      ),
      find.text('Start date'),
      find.descendant(of: field, matching: find.text('Select date')),
    ];
    final today = DateUtils.dateOnly(DateTime.now());
    for (final target in targets) {
      await tester.tap(target);
      await tester.pumpAndSettle();
      final picker = tester.widget<CalendarDatePicker>(
        find.byType(CalendarDatePicker),
      );
      expect(picker.firstDate, today);
      expect(picker.initialDate, today);
      final labels = MaterialLocalizations.of(
        tester.element(find.byType(DatePickerDialog)),
      );
      await tester.tap(find.text(labels.cancelButtonLabel));
      await tester.pumpAndSettle();
    }
    final rect = tester.getRect(field);
    await tester.tapAt(Offset(rect.right - 6, rect.center.dy));
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsOneWidget);
    await selectPickerDate(tester, today);
    final labels = MaterialLocalizations.of(tester.element(field));
    expect(
      find.text(
        '${labels.formatMediumDate(today)}, ${labels.formatYear(today)}',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'end picker follows start, dependent date corrects, and creation saves both',
    (tester) async {
      final projects = FakeProjectRepository();
      await showApp(tester, projects);
      await tester.tap(find.byKey(const Key('new-project-button')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('project-name-field')),
        'Dated project',
      );
      final today = DateUtils.dateOnly(DateTime.now());
      final startField = find.byKey(const Key('project-start-date-field'));
      final endField = find.byKey(const Key('project-end-date-field'));
      await tester.ensureVisible(endField);
      await tester.tap(
        find.descendant(
          of: endField,
          matching: find.byIcon(Icons.calendar_today_outlined),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<CalendarDatePicker>(find.byType(CalendarDatePicker))
            .firstDate,
        today,
      );
      await selectPickerDate(tester, today);
      await tester.ensureVisible(startField);
      await tester.tap(startField);
      await tester.pumpAndSettle();
      final future = DateTime(today.year, today.month, today.day + 45);
      await selectPickerDate(tester, future);
      final labels = MaterialLocalizations.of(tester.element(startField));
      final text =
          '${labels.formatMediumDate(future)}, ${labels.formatYear(future)}';
      expect(find.text(text), findsNWidgets(2));
      await tester.ensureVisible(endField);
      await tester.tap(endField);
      await tester.pumpAndSettle();
      final picker = tester.widget<CalendarDatePicker>(
        find.byType(CalendarDatePicker),
      );
      expect(picker.firstDate, future);
      expect(picker.initialDate, future);
      await selectPickerDate(tester, future);
      await tester.tap(find.byKey(const Key('save-project-button')));
      await tester.pumpAndSettle();
      expect(projects.stored.single.project.startDate, future);
      expect(projects.stored.single.project.endDate, future);
      expect(find.text('Kanban Board'), findsOneWidget);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.text('My Projects'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'clearing optional dates changes the form without opening a picker',
    (tester) async {
      final projects = FakeProjectRepository();
      await showApp(tester, projects);
      await tester.tap(find.byKey(const Key('new-project-button')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('project-name-field')),
        'No dates',
      );
      for (final label in ['Start date', 'End date']) {
        final field = find.byKey(
          Key(
            label == 'Start date'
                ? 'project-start-date-field'
                : 'project-end-date-field',
          ),
        );
        await tester.ensureVisible(field);
        await tester.tap(field);
        await tester.pumpAndSettle();
        await selectPickerDate(tester, DateUtils.dateOnly(DateTime.now()));
        await tester.tap(find.byTooltip('Clear $label'));
        await tester.pumpAndSettle();
        expect(find.byType(DatePickerDialog), findsNothing);
        expect(
          find.descendant(of: field, matching: find.text('Select date')),
          findsOneWidget,
        );
      }
      await tester.tap(find.byKey(const Key('save-project-button')));
      await tester.pumpAndSettle();
      expect(projects.stored.single.project.startDate, isNull);
      expect(projects.stored.single.project.endDate, isNull);
    },
  );

  testWidgets(
    'editing preserves past dates and safely clamps unexpected picker values',
    (tester) async {
      final projects = FakeProjectRepository(
        items: [sampleProject('1', 'Existing')],
      );
      final stored = projects.stored.single.project.copyWith(
        startDate: DateTime(1990, 1, 1),
        endDate: DateTime(2200, 1, 1),
      );
      await projects.updateProject(stored);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: CreateProjectScreen(repository: projects, project: stored),
        ),
      );
      await tester.pumpAndSettle();
      for (final start in [true, false]) {
        final field = find.byKey(
          Key(start ? 'project-start-date-field' : 'project-end-date-field'),
        );
        await tester.ensureVisible(field);
        await tester.tap(field);
        await tester.pumpAndSettle();
        final picker = tester.widget<CalendarDatePicker>(
          find.byType(CalendarDatePicker),
        );
        expect(picker.firstDate, DateTime(2000));
        expect(picker.initialDate, start ? DateTime(2000) : DateTime(2100));
        final labels = MaterialLocalizations.of(
          tester.element(find.byType(DatePickerDialog)),
        );
        await tester.tap(find.text(labels.cancelButtonLabel));
        await tester.pumpAndSettle();
      }
      expect(projects.stored.single.project.startDate, DateTime(1990, 1, 1));
      expect(projects.stored.single.project.endDate, DateTime(2200, 1, 1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'date fields wrap on narrow screens with large text and expose tap semantics',
    (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final today = DateUtils.dateOnly(DateTime.now());
      final projects = FakeProjectRepository();
      Future<void> showForm(double scale) => tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: CreateProjectScreen(repository: projects),
        ),
      );
      await showForm(1);
      await tester.pumpAndSettle();
      for (final start in [true, false]) {
        final field = find.byKey(
          Key(start ? 'project-start-date-field' : 'project-end-date-field'),
        );
        await tester.ensureVisible(field);
        await tester.tap(field);
        await tester.pumpAndSettle();
        await selectPickerDate(tester, today);
      }
      await showForm(2);
      await tester.pumpAndSettle();
      final semantics = tester.ensureSemantics();
      for (final start in [true, false]) {
        final field = find.byKey(
          Key(start ? 'project-start-date-field' : 'project-end-date-field'),
        );
        await tester.scrollUntilVisible(
          field,
          150,
          scrollable: find
              .descendant(
                of: find.byType(ListView),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.pumpAndSettle();
        expect(tester.getSize(field).height, greaterThanOrEqualTo(44));
        final data = tester.getSemantics(field).getSemanticsData();
        expect(data.hasAction(SemanticsAction.tap), true);
        expect(data.flagsCollection.isButton, true);
        expect(data.label, contains(start ? 'Start date' : 'End date'));
        expect(tester.takeException(), isNull);
      }
      semantics.dispose();
    },
  );

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
