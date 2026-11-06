import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skilltrack/core/utils/date_formatter.dart';
import 'package:skilltrack/core/errors/app_exception.dart';
import 'package:skilltrack/features/ai_task_generation/models/task_generation_request.dart';
import 'package:skilltrack/features/kanban/models/kanban_filter.dart';
import 'package:skilltrack/features/kanban/models/kanban_status.dart';
import 'package:skilltrack/features/kanban/models/kanban_task.dart';
import 'package:skilltrack/features/kanban/viewmodels/kanban_view_model.dart';
import 'package:skilltrack/features/kanban/widgets/task_form_sheet.dart';
import 'package:skilltrack/features/projects/models/learning_project.dart';
import 'fake_repository.dart';

final _title = find.byKey(const Key('task-title-field'));
final _save = find.byKey(const Key('save-task-button'));

Future<void> _showForm(
  WidgetTester tester,
  FakeKanbanRepository repository,
  DateTime Function() clock, {
  KanbanTask? task,
}) async {
  final model = KanbanViewModel(repository, clock: clock);
  addTearDown(model.dispose);
  await model.initialize('board-1');
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
      initialRoute: '/form',
      routes: {
        '/': (_) => const Scaffold(body: Text('Board')),
        '/form': (_) => TaskFormSheet(viewModel: model, task: task),
      },
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openDate(WidgetTester tester) async {
  await tester.ensureVisible(find.text('Deadline'));
  await tester.tap(find.text('Deadline'));
  await tester.pumpAndSettle();
}

Future<void> _confirmPicker(WidgetTester tester) async {
  await tester.tap(find.text('OK'));
  await tester.pumpAndSettle();
}

Future<void> _pickTime(
  WidgetTester tester,
  String previousLabel,
  String hour,
  String minute,
) async {
  final timeButton = find.widgetWithText(TextButton, previousLabel);
  await tester.ensureVisible(timeButton);
  await tester.pumpAndSettle();
  await tester.tap(timeButton);
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('Switch to text input mode'));
  await tester.pumpAndSettle();
  final fields = find.descendant(
    of: find.byType(TimePickerDialog),
    matching: find.byType(TextField),
  );
  await tester.enterText(fields.at(0), hour);
  await tester.enterText(fields.at(1), minute);
  await _confirmPicker(tester);
}

void main() {
  test('Malaysia wall components round trip with microsecond precision', () {
    for (final instant in [
      DateTime.utc(2026, 11, 1, 16, 30, 2, 123, 456),
      DateTime.utc(2026, 3, 7, 18, 30),
      DateTime.utc(2026, 11, 2, 10),
    ]) {
      final wall = DateFormatter.malaysiaTime(instant);
      expect(DateFormatter.fromMalaysia(wall), instant);
    }
    final wall = DateFormatter.malaysiaTime(DateTime.utc(2026, 3, 7, 18, 30));
    expect(
      [wall.year, wall.month, wall.day, wall.hour, wall.minute],
      [2026, 3, 8, 2, 30],
    );
  });
  test(
    'Malaysia today changes at 16:00 UTC and calendar dates are not shifted',
    () {
      expect(
        DateFormatter.today(now: DateTime.utc(2026, 11, 1, 15, 59)).day,
        1,
      );
      expect(DateFormatter.today(now: DateTime.utc(2026, 11, 1, 16)).day, 2);
      expect(
        DateFormatter.short(DateTime.utc(2026, 11, 1, 16, 30)),
        '02/11/2026',
      );
      expect(
        DateFormatter.calendarDate(DateTime.utc(2026, 11, 2)),
        '02/11/2026',
      );
    },
  );
  test('timed deadlines save an explicit UTC instant', () {
    final utc = DateFormatter.fromMalaysia(DateTime.utc(2026, 11, 2, 18));
    final task = sampleTask(
      't',
      'Task',
      KanbanStatus.todo,
      deadline: utc,
    ).copyWith(deadlineHasTime: true);
    expect(task.toMap()['deadline'], '2026-11-02T10:00:00.000Z');
    expect(task.toMap()['deadline_has_time'], true);
    expect(KanbanTask.fromMap(task.toMap()).deadline, utc);
    expect(task.copyWith().deadlineHasTime, true);
    expect(task.copyWith(clearDeadline: true).deadlineHasTime, null);
  });
  test('legacy timestamps and unknown classification are preserved', () {
    final task = KanbanTask.fromMap(
      {
        ...sampleTask('t', 'Task', KanbanStatus.todo).toMap(),
        'deadline': '2026-11-02T00:30:00+00',
      }..remove('deadline_has_time'),
    );
    expect(task.deadlineHasTime, null);
    expect(task.hasDeadlineTime, true);
    expect(task.toMap()['deadline'], '2026-11-02T00:30:00.000Z');
  });
  test('date-only cutoff and explicit midnight remain distinct', () {
    final calendar = DateTime(2026, 11, 2);
    final end = DateFormatter.endOfDateUtc(calendar);
    final dateOnly = sampleTask(
      'all',
      'All day',
      KanbanStatus.todo,
      deadline: end,
    ).copyWith(deadlineHasTime: false);
    final midnight = dateOnly.copyWith(
      deadline: DateFormatter.fromMalaysia(calendar),
      deadlineHasTime: true,
    );
    expect(end, DateTime.utc(2026, 11, 2, 15, 59, 59, 999));
    expect(dateOnly.hasDeadlineTime, false);
    expect(midnight.hasDeadlineTime, true);
    expect(midnight.deadline, DateTime.utc(2026, 11, 1, 16));
    expect(dateOnly.isOverdueAt(end), false);
    expect(dateOnly.isOverdueAt(DateTime.utc(2026, 11, 2, 16)), true);
  });
  test('timed overdue checks use instants at the Malaysia date boundary', () {
    final task = sampleTask(
      't',
      'Task',
      KanbanStatus.todo,
      deadline: DateTime.utc(2026, 11, 1, 16, 30),
    );
    expect(task.isOverdueAt(DateTime.utc(2026, 11, 1, 16)), false);
    expect(task.isOverdueAt(DateTime.utc(2026, 11, 1, 16, 30)), false);
    expect(task.isOverdueAt(DateTime.utc(2026, 11, 1, 16, 31)), true);
    expect(task.isDueSoonAt(DateTime.utc(2026, 11, 1, 16)), true);
  });
  test('AI context uses the displayed Malaysia calendar date', () {
    final summary = ExistingTaskSummary(
      title: 'Task',
      status: 'todo',
      sortOrder: 0,
      deadline: DateTime.utc(2026, 11, 1, 16, 30),
    );
    expect(summary.toRequestJson()['deadline'], '2026-11-02');
  });
  test('project dates retain their original calendar values', () {
    final project = LearningProject.fromMap({
      'id': 'p',
      'owner_id': 'u',
      'name': 'Project',
      'start_date': '2026-11-02',
      'end_date': '2026-11-03',
    });
    expect(project.toMap()['start_date'], '2026-11-02');
    expect(project.toMap()['end_date'], '2026-11-03');
  });
  test(
    'date filters include start and last millisecond, excluding next midnight',
    () async {
      final model = KanbanViewModel(
        FakeKanbanRepository(
          tasks: [
            sampleTask(
              'before',
              'Before',
              KanbanStatus.todo,
              deadline: DateTime.utc(2026, 11, 1, 15, 59, 59, 999),
            ),
            sampleTask(
              'start',
              'Start',
              KanbanStatus.todo,
              deadline: DateTime.utc(2026, 11, 1, 16),
            ),
            sampleTask(
              'end',
              'End',
              KanbanStatus.todo,
              deadline: DateTime.utc(2026, 11, 2, 15, 59, 59, 999),
            ),
            sampleTask(
              'after',
              'After',
              KanbanStatus.todo,
              deadline: DateTime.utc(2026, 11, 2, 16),
            ),
          ],
        ),
      );
      addTearDown(model.dispose);
      await model.initialize('board-1');
      model.applyFilter(
        KanbanFilter(
          deadlineStart: DateTime(2026, 11, 2),
          deadlineEnd: DateTime(2026, 11, 2),
        ),
      );
      expect(model.visibleTasks(KanbanStatus.todo).map((t) => t.id), [
        'start',
        'end',
      ]);
    },
  );
  for (final hasTime in [true, false]) {
    testWidgets(
      'editor preserves ${hasTime ? "selected time" : "No time"} through save',
      (tester) async {
        final instant = hasTime
            ? DateTime.utc(2026, 11, 2, 10, 0, 2, 123, 456)
            : DateFormatter.endOfDateUtc(DateTime(2026, 11, 2));
        final task = sampleTask(
          't',
          'Task',
          KanbanStatus.todo,
          deadline: instant,
        ).copyWith(deadlineHasTime: hasTime);
        final repo = FakeKanbanRepository(tasks: [task]);
        final model = KanbanViewModel(repo);
        await model.initialize('board-1');
        await tester.pumpWidget(
          MaterialApp(
            home: TaskFormSheet(viewModel: model, task: task),
          ),
        );
        if (hasTime) {
          final context = tester.element(find.byType(TaskFormSheet));
          expect(
            find.text(const TimeOfDay(hour: 18, minute: 0).format(context)),
            findsOneWidget,
          );
        } else {
          expect(find.text('No time'), findsOneWidget);
        }
        await tester.ensureVisible(find.byKey(const Key('save-task-button')));
        await tester.tap(find.byKey(const Key('save-task-button')));
        await tester.pumpAndSettle();
        expect(repo.stored.single.deadline, instant);
        expect(repo.stored.single.deadlineHasTime, hasTime);
        await tester.pumpWidget(const SizedBox());
        model.dispose();
      },
    );
  }
  testWidgets('explicit midnight remains timed when reopening and saving', (
    tester,
  ) async {
    final task = sampleTask(
      't',
      'Midnight',
      KanbanStatus.todo,
      deadline: DateTime.utc(2026, 11, 1, 16),
    ).copyWith(deadlineHasTime: true);
    final repo = FakeKanbanRepository(tasks: [task]);
    final model = KanbanViewModel(repo);
    await model.initialize('board-1');
    await tester.pumpWidget(
      MaterialApp(
        home: TaskFormSheet(viewModel: model, task: task),
      ),
    );
    final context = tester.element(find.byType(TaskFormSheet));
    expect(
      find.text(const TimeOfDay(hour: 0, minute: 0).format(context)),
      findsOneWidget,
    );
    expect(find.text('No time'), findsNothing);
    await tester.ensureVisible(find.byKey(const Key('save-task-button')));
    await tester.tap(find.byKey(const Key('save-task-button')));
    await tester.pumpAndSettle();
    expect(repo.stored.single.deadline, task.deadline);
    expect(repo.stored.single.deadlineHasTime, true);
    await tester.pumpWidget(const SizedBox());
    model.dispose();
  });
  testWidgets(
    'removing time keeps the Malaysia date and saves its end-of-day cutoff',
    (tester) async {
      final task = sampleTask(
        't',
        'Legacy',
        KanbanStatus.todo,
        deadline: DateTime.utc(2026, 11, 1, 16, 30),
      );
      final repo = FakeKanbanRepository(tasks: [task]);
      final model = KanbanViewModel(
        repo,
        clock: () => DateTime.utc(2026, 11, 2, 7),
      );
      await model.initialize('board-1');
      await tester.pumpWidget(
        MaterialApp(
          home: TaskFormSheet(viewModel: model, task: task),
        ),
      );
      await tester.tap(find.byTooltip('Task options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove deadline time'));
      await tester.pumpAndSettle();
      expect(find.text('No time'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('save-task-button')));
      await tester.tap(find.byKey(const Key('save-task-button')));
      await tester.pumpAndSettle();
      expect(
        repo.stored.single.deadline,
        DateTime.utc(2026, 11, 2, 15, 59, 59, 999),
      );
      expect(repo.stored.single.deadlineHasTime, false);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );

  group('manual deadline validation', () {
    // 14:30 in Malaysia, regardless of the process timezone.
    final afternoon = DateTime.utc(2026, 11, 6, 6, 30);

    testWidgets('yesterday is disabled and today saves at Malaysia day end', (
      tester,
    ) async {
      final repository = FakeKanbanRepository();
      await _showForm(tester, repository, () => afternoon.toLocal());
      await tester.enterText(_title, 'Due today');
      await _openDate(tester);
      final dialog = tester.widget<DatePickerDialog>(
        find.byType(DatePickerDialog),
      );
      expect(dialog.firstDate, DateTime(2026, 11, 6));
      expect(dialog.currentDate, DateTime(2026, 11, 6));
      final yesterday = find.ancestor(
        of: find.text('5'),
        matching: find.byWidgetPredicate(
          (widget) => widget is Semantics && widget.properties.enabled == false,
        ),
      );
      expect(yesterday, findsOneWidget);
      await tester.tap(find.text('6'));
      await tester.pumpAndSettle();
      await _confirmPicker(tester);
      await tester.tap(_save);
      await tester.pumpAndSettle();
      expect(
        repository.stored.single.deadline,
        DateTime.utc(2026, 11, 6, 15, 59, 59, 999),
      );
      expect(repository.stored.single.deadlineHasTime, false);
    });

    testWidgets(
      'today accepts a future time and rejects elapsed time without replacing it',
      (tester) async {
        final repository = FakeKanbanRepository();
        await _showForm(tester, repository, () => afternoon);
        await tester.enterText(_title, 'Timed task');
        await _pickTime(tester, 'No time', '15', '00');
        expect(find.text('15:00'), findsOneWidget);
        await _pickTime(tester, '15:00', '14', '29');
        expect(find.text(AppErrorMessages.deadlineTimePassed), findsOneWidget);
        expect(find.text('15:00'), findsOneWidget);
        expect(repository.stored, isEmpty);
        await tester.tap(_save);
        await tester.pumpAndSettle();
        expect(repository.stored.single.deadline, DateTime.utc(2026, 11, 6, 7));
        expect(repository.stored.single.deadlineHasTime, true);
      },
    );

    testWidgets(
      'future date accepts midnight, but changing it to today requires a new time',
      (tester) async {
        final repository = FakeKanbanRepository();
        await _showForm(tester, repository, () => afternoon);
        await tester.enterText(_title, 'Keep the title');
        await _openDate(tester);
        await tester.tap(find.text('7'));
        await tester.pumpAndSettle();
        await _confirmPicker(tester);
        await _pickTime(tester, 'No time', '00', '00');
        expect(find.text('00:00'), findsOneWidget);
        expect(find.text(AppErrorMessages.deadlineTimePassed), findsNothing);

        await _openDate(tester);
        await tester.tap(find.text('6'));
        await tester.pumpAndSettle();
        await _confirmPicker(tester);
        await tester.tap(_save);
        await tester.pumpAndSettle();
        expect(find.byType(TaskFormSheet), findsOneWidget);
        expect(find.text(AppErrorMessages.deadlineTimePassed), findsOneWidget);
        expect(find.text('Keep the title'), findsOneWidget);
        expect(find.text('00:00'), findsOneWidget);
        expect(repository.stored, isEmpty);

        await _openDate(tester);
        await tester.tap(find.text('7'));
        await tester.pumpAndSettle();
        await _confirmPicker(tester);
        await tester.tap(_save);
        await tester.pumpAndSettle();
        expect(
          repository.stored.single.deadline,
          DateTime.utc(2026, 11, 6, 16),
        );
      },
    );

    testWidgets('a time that expires before Save leaves the new form intact', (
      tester,
    ) async {
      var now = afternoon;
      final repository = FakeKanbanRepository();
      await _showForm(tester, repository, () => now);
      await tester.enterText(_title, 'Retained title');
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Description or notes'),
        'Retained description',
      );
      await _pickTime(tester, 'No time', '14', '31');
      now = now.add(const Duration(minutes: 2));
      await tester.tap(_save);
      await tester.pumpAndSettle();
      expect(repository.stored, isEmpty);
      expect(find.text(AppErrorMessages.deadlineTimePassed), findsOneWidget);
      expect(find.text('Retained title'), findsOneWidget);
      expect(find.text('Retained description'), findsOneWidget);
      expect(find.text('14:31'), findsOneWidget);
    });

    testWidgets(
      'overdue picker opens at today and cancelling preserves the exact stored deadline',
      (tester) async {
        final deadline = DateTime.utc(2026, 11, 5, 15, 59);
        final task = sampleTask(
          'old',
          'Overdue',
          KanbanStatus.todo,
          deadline: deadline,
        ).copyWith(deadlineHasTime: false);
        final repository = FakeKanbanRepository(tasks: [task]);
        await _showForm(tester, repository, () => afternoon, task: task);
        await _openDate(tester);
        final dialog = tester.widget<DatePickerDialog>(
          find.byType(DatePickerDialog),
        );
        expect(dialog.initialDate, DateTime(2026, 11, 6));
        expect(dialog.firstDate, DateTime(2026, 11, 6));
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        await tester.enterText(_title, 'Renamed overdue task');
        await tester.tap(_save);
        await tester.pumpAndSettle();
        expect(repository.stored.single.title, 'Renamed overdue task');
        expect(repository.stored.single.deadline, deadline);
        expect(repository.stored.single.deadlineHasTime, false);
      },
    );

    testWidgets('an overdue deadline can be replaced with a valid date', (
      tester,
    ) async {
      final task = sampleTask(
        'old',
        'Overdue',
        KanbanStatus.todo,
        deadline: DateTime.utc(2026, 11, 5, 15, 59),
      ).copyWith(deadlineHasTime: false);
      final repository = FakeKanbanRepository(tasks: [task]);
      await _showForm(tester, repository, () => afternoon, task: task);
      await _openDate(tester);
      await _confirmPicker(tester);
      await tester.tap(_save);
      await tester.pumpAndSettle();
      expect(
        repository.stored.single.deadline,
        DateTime.utc(2026, 11, 6, 15, 59, 59, 999),
      );
      expect(repository.stored.single.deadlineHasTime, false);
    });

    testWidgets('an overdue deadline can be cleared', (tester) async {
      final task = sampleTask(
        'old',
        'Overdue',
        KanbanStatus.todo,
        deadline: DateTime.utc(2026, 11, 5, 7),
      );
      final repository = FakeKanbanRepository(tasks: [task]);
      await _showForm(tester, repository, () => afternoon, task: task);
      await tester.tap(find.byTooltip('Clear deadline'));
      await tester.tap(_save);
      await tester.pumpAndSettle();
      expect(repository.stored.single.deadline, isNull);
    });

    testWidgets('a deadline expiring while Edit is open must be corrected', (
      tester,
    ) async {
      var now = afternoon;
      final deadline = now.add(const Duration(minutes: 1));
      final task = sampleTask(
        'old',
        'Task',
        KanbanStatus.todo,
        deadline: deadline,
      );
      final repository = FakeKanbanRepository(tasks: [task]);
      await _showForm(tester, repository, () => now, task: task);
      await tester.enterText(_title, 'Renamed');
      now = now.add(const Duration(minutes: 2));
      await tester.tap(_save);
      await tester.pumpAndSettle();
      expect(repository.stored.single.title, 'Task');
      expect(find.text(AppErrorMessages.deadlineTimePassed), findsOneWidget);
      await _pickTime(tester, '14:31', '15', '00');
      await tester.tap(_save);
      await tester.pumpAndSettle();
      expect(repository.stored.single.title, 'Renamed');
      expect(repository.stored.single.deadline, DateTime.utc(2026, 11, 6, 7));
    });

    testWidgets('the date-only selection expires at Malaysia midnight', (
      tester,
    ) async {
      var now = DateTime.utc(2026, 11, 5, 15, 59, 59);
      final repository = FakeKanbanRepository();
      await _showForm(tester, repository, () => now);
      await tester.enterText(_title, 'Midnight test');
      await _openDate(tester);
      final before = tester.widget<DatePickerDialog>(
        find.byType(DatePickerDialog),
      );
      expect(before.firstDate, DateTime(2026, 11, 5));
      await _confirmPicker(tester);

      now = DateTime.utc(2026, 11, 5, 16);
      await tester.tap(_save);
      await tester.pumpAndSettle();
      expect(repository.stored, isEmpty);
      expect(find.text(AppErrorMessages.deadlineDatePassed), findsOneWidget);
      await _openDate(tester);
      final after = tester.widget<DatePickerDialog>(
        find.byType(DatePickerDialog),
      );
      expect(after.firstDate, DateTime(2026, 11, 6));
      expect(after.initialDate, DateTime(2026, 11, 6));
      await _confirmPicker(tester);
      await tester.tap(_save);
      await tester.pumpAndSettle();
      expect(
        repository.stored.single.deadline,
        DateTime.utc(2026, 11, 6, 15, 59, 59, 999),
      );
    });
  });
}
