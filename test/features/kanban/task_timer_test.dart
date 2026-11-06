import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skilltrack/features/kanban/models/kanban_status.dart';
import 'package:skilltrack/features/kanban/models/kanban_task.dart';
import 'package:skilltrack/features/kanban/models/task_priority.dart';
import 'package:skilltrack/features/kanban/viewmodels/kanban_view_model.dart';
import 'package:skilltrack/features/kanban/widgets/task_timer_section.dart';

import 'fake_repository.dart';

class _PendingTimerRepository extends FakeKanbanRepository {
  _PendingTimerRepository(KanbanTask task) : super(tasks: [task]);
  final gate = Completer<void>();
  int attempts = 0;

  @override
  Future<KanbanTask> setTaskTimerPaused(KanbanTask task, bool paused) async {
    attempts++;
    await gate.future;
    return super.setTaskTimerPaused(task, paused);
  }
}

void main() {
  final now = DateTime.utc(2026, 10, 31, 12);
  final base = sampleTask('1', 'Study', KanbanStatus.inProgress);

  test('timer fields parse safely and remain server managed', () {
    final task = KanbanTask.fromMap({
      ...base.toMap(),
      'elapsed_seconds': 120,
      'tracking_started_at': '2026-10-31T20:00:00+08:00',
    });
    expect(task.elapsedSeconds, 120);
    expect(task.trackingStartedAt, now);
    expect(task.trackingStartedAt!.isUtc, isTrue);
    expect(task.toMap(), isNot(contains('elapsed_seconds')));
    expect(task.toMap(), isNot(contains('tracking_started_at')));
    for (final value in [null, -1, 'bad', double.infinity]) {
      final invalid = KanbanTask.fromMap({
        ...base.toMap(),
        'elapsed_seconds': value,
        'tracking_started_at': 'bad',
      });
      expect(invalid.elapsedSeconds, 0);
      expect(invalid.trackingStartedAt, isNull);
    }
  });

  test('duration survives rehydration without resetting the session', () {
    final row = {
      ...base.toMap(),
      'elapsed_seconds': 60,
      'tracking_started_at': now
          .subtract(const Duration(minutes: 2))
          .toIso8601String(),
    };
    expect(KanbanTask.fromMap(row).trackedDurationAt(now).inSeconds, 180);
    expect(
      KanbanTask.fromMap(
        row,
      ).trackedDurationAt(now.add(const Duration(hours: 12))).inSeconds,
      43380,
    );
  });

  test(
    'paused and inactive tasks retain saved duration; future starts cannot subtract it',
    () {
      final paused = base.copyWith(elapsedSeconds: 90);
      expect(paused.trackedDurationAt(now).inSeconds, 90);
      expect(
        paused
            .copyWith(trackingStartedAt: now.add(const Duration(hours: 1)))
            .trackedDurationAt(now)
            .inSeconds,
        90,
      );
      for (final status in [KanbanStatus.todo, KanbanStatus.completed]) {
        expect(
          paused
              .copyWith(
                status: status,
                trackingStartedAt: now.subtract(const Duration(hours: 1)),
              )
              .trackedDurationAt(now)
              .inSeconds,
          90,
        );
      }
      expect(
        paused.copyWith(isArchived: true, trackingStartedAt: now).isTracking,
        isFalse,
      );
    },
  );

  test('timer copy/equality/hash preserve and clear timer values', () {
    final task = base.copyWith(elapsedSeconds: 10, trackingStartedAt: now);
    expect(task.copyWith(), task);
    expect(task.copyWith().hashCode, task.hashCode);
    expect(task, isNot(base));
    expect(
      task.copyWith(clearTrackingStartedAt: true).trackingStartedAt,
      isNull,
    );
    expect(task.copyWith(clearTrackingStartedAt: true).elapsedSeconds, 10);
  });

  test('status transitions start, stop and retain accumulated time', () async {
    final repo = FakeKanbanRepository(
      tasks: [base.copyWith(status: KanbanStatus.todo, elapsedSeconds: 60)],
    );
    final model = KanbanViewModel(repo);
    addTearDown(model.dispose);
    await model.initialize();
    expect(await model.moveTask('1', KanbanStatus.inProgress), isTrue);
    expect(model.allTasks.single.isTracking, isTrue);
    expect(model.allTasks.single.elapsedSeconds, 60);
    expect(await model.completeTask('1'), isTrue);
    final completed = model.allTasks.single;
    expect(completed.trackingStartedAt, isNull);
    expect(completed.elapsedSeconds, greaterThanOrEqualTo(60));
    expect(completed.completedAt, isNotNull);
    expect(await model.reopenTask('1', KanbanStatus.inProgress), isTrue);
    expect(model.allTasks.single.isTracking, isTrue);
    expect(model.allTasks.single.completedAt, isNull);
    expect(await model.moveTask('1', KanbanStatus.todo), isTrue);
    expect(model.allTasks.single.isTracking, isFalse);
    expect(model.allTasks.single.elapsedSeconds, greaterThanOrEqualTo(60));
  });

  test('pause/resume preserves duration, deadline and stalled state', () async {
    final deadline = DateTime.utc(2026, 11, 10);
    final repo = FakeKanbanRepository(
      tasks: [
        base.copyWith(
          elapsedSeconds: 45,
          trackingStartedAt: DateTime.now().toUtc().subtract(
            const Duration(seconds: 30),
          ),
          deadline: deadline,
          isStalled: true,
          stagnationScore: 80,
        ),
      ],
    );
    final model = KanbanViewModel(repo);
    addTearDown(model.dispose);
    await model.initialize();
    expect(await model.setTaskTimerPaused('1', true), isTrue);
    final paused = model.allTasks.single;
    expect(paused.isTracking, isFalse);
    expect(paused.elapsedSeconds, greaterThanOrEqualTo(75));
    expect(paused.status, KanbanStatus.inProgress);
    expect(paused.deadline, deadline);
    expect(paused.isStalled, isTrue);
    expect(await model.setTaskTimerPaused('1', true), isTrue);
    expect(repo.timerCalls, 1);
    expect(await model.setTaskTimerPaused('1', false), isTrue);
    expect(model.allTasks.single.elapsedSeconds, paused.elapsedSeconds);
    expect(model.allTasks.single.isTracking, isTrue);
    expect(await model.resumeTask('1'), isTrue);
    expect(model.allTasks.single.isTracking, isTrue);
    expect(model.allTasks.single.isStalled, isFalse);
  });

  test(
    'duplicate requests are blocked while a timer save is pending',
    () async {
      final repo = _PendingTimerRepository(
        base.copyWith(trackingStartedAt: DateTime.now().toUtc()),
      );
      final model = KanbanViewModel(repo);
      addTearDown(model.dispose);
      await model.initialize();
      final pending = model.setTaskTimerPaused('1', true);
      expect(model.isSaving, isTrue);
      expect(await model.setTaskTimerPaused('1', true), isFalse);
      expect(repo.attempts, 1);
      repo.gate.complete();
      expect(await pending, isTrue);
      expect(model.isSaving, isFalse);
    },
  );

  test('failed pause keeps the running session and allows retry', () async {
    final task = base.copyWith(
      trackingStartedAt: DateTime.now().toUtc(),
      elapsedSeconds: 30,
    );
    final repo = FakeKanbanRepository(tasks: [task])..failTimer = true;
    final model = KanbanViewModel(repo);
    addTearDown(model.dispose);
    await model.initialize();
    expect(await model.setTaskTimerPaused('1', true), isFalse);
    expect(model.allTasks.single, task);
    expect(model.errorMessage, isNotNull);
    expect(model.isSaving, isFalse);
    repo.failTimer = false;
    expect(await model.setTaskTimerPaused('1', true), isTrue);
  });

  test(
    'reordering or editing a paused task does not resume its timer',
    () async {
      final repo = FakeKanbanRepository(
        tasks: [
          base.copyWith(elapsedSeconds: 90),
          sampleTask('2', 'Other', KanbanStatus.inProgress, order: 2000),
        ],
      );
      final model = KanbanViewModel(repo);
      addTearDown(model.dispose);
      await model.initialize();
      await model.moveTask('1', KanbanStatus.inProgress, newIndex: 1);
      final task = model.allTasks.singleWhere((task) => task.id == '1');
      expect(task.trackingStartedAt, isNull);
      expect(
        await model.updateTask(
          task,
          title: 'Renamed',
          description: '',
          status: task.status,
          priority: TaskPriority.medium,
        ),
        isTrue,
      );
      expect(
        model.allTasks.singleWhere((task) => task.id == '1').trackingStartedAt,
        isNull,
      );
      expect(
        model.allTasks.singleWhere((task) => task.id == '1').elapsedSeconds,
        90,
      );
    },
  );

  test('task editor status changes use the same tracking operation', () async {
    final repo = FakeKanbanRepository(
      tasks: [base.copyWith(status: KanbanStatus.todo)],
    );
    final model = KanbanViewModel(repo);
    addTearDown(model.dispose);
    await model.initialize();
    expect(
      await model.updateTask(
        model.allTasks.single,
        title: 'Study',
        description: '',
        status: KanbanStatus.inProgress,
        priority: TaskPriority.medium,
      ),
      isTrue,
    );
    expect(repo.moveCalls, 1);
    expect(model.allTasks.single.isTracking, isTrue);
  });

  test(
    'creating directly in progress starts with fresh tracked time',
    () async {
      final repo = FakeKanbanRepository();
      final model = KanbanViewModel(repo);
      addTearDown(model.dispose);
      await model.initialize();
      expect(
        await model.createTask(title: 'Study', status: KanbanStatus.inProgress),
        isTrue,
      );
      expect(model.allTasks.single.isTracking, isTrue);
      expect(model.allTasks.single.elapsedSeconds, 0);
    },
  );

  test('archive stops a running session and restore keeps it paused', () async {
    final repo = FakeKanbanRepository(
      tasks: [
        base.copyWith(
          trackingStartedAt: DateTime.now().toUtc().subtract(
            const Duration(seconds: 10),
          ),
        ),
      ],
    );
    final model = KanbanViewModel(repo);
    addTearDown(model.dispose);
    await model.initialize();
    expect(await model.archiveTask('1'), isTrue);
    expect(repo.stored.single.trackingStartedAt, isNull);
    expect(repo.stored.single.elapsedSeconds, greaterThanOrEqualTo(10));
    expect(await model.restoreTask('1'), isTrue);
    expect(model.allTasks.single.isTracking, isFalse);
  });

  testWidgets(
    'timer control reflects running/paused state and disables during saves',
    (tester) async {
      var toggles = 0;
      Future<void> show(KanbanTask task, {bool saving = false}) =>
          tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: TaskTimerSection(
                  task: task,
                  isSaving: saving,
                  onToggle: () => toggles++,
                ),
              ),
            ),
          );
      await show(base.copyWith(elapsedSeconds: 3661));
      expect(find.text('01:01:01'), findsOneWidget);
      expect(find.text('Resume timer'), findsOneWidget);
      await tester.tap(find.text('Resume timer'));
      expect(toggles, 1);
      await show(
        base.copyWith(trackingStartedAt: DateTime.now().toUtc()),
        saving: true,
      );
      expect(find.text('Pause timer'), findsOneWidget);
      expect(
        tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
        isNull,
      );
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('completed timer supports over 24 hours and fits enlarged text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: Scaffold(
            body: TaskTimerSection(
              task: base.copyWith(
                status: KanbanStatus.completed,
                elapsedSeconds: 90000,
              ),
              isSaving: false,
              onToggle: () {},
            ),
          ),
        ),
      ),
    );
    expect(find.text('25:00:00'), findsOneWidget);
    expect(find.byType(OutlinedButton), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
