import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skilltrack/core/utils/date_formatter.dart';
import 'package:skilltrack/features/ai_task_generation/models/task_generation_request.dart';
import 'package:skilltrack/features/kanban/models/kanban_filter.dart';
import 'package:skilltrack/features/kanban/models/kanban_status.dart';
import 'package:skilltrack/features/kanban/models/kanban_task.dart';
import 'package:skilltrack/features/kanban/viewmodels/kanban_view_model.dart';
import 'package:skilltrack/features/kanban/widgets/task_form_sheet.dart';
import 'package:skilltrack/features/projects/models/learning_project.dart';
import 'fake_repository.dart';

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
      final model = KanbanViewModel(repo);
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
}
