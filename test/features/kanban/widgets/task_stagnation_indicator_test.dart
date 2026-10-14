import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skilltrack/app/skill_track_app.dart';
import 'package:skilltrack/core/utils/date_formatter.dart';
import 'package:skilltrack/features/kanban/models/kanban_status.dart';
import 'package:skilltrack/features/kanban/models/kanban_task.dart';
import 'package:skilltrack/features/kanban/models/task_activity.dart';
import 'package:skilltrack/features/kanban/viewmodels/kanban_view_model.dart';
import 'package:skilltrack/features/kanban/widgets/kanban_task_card.dart';
import 'package:skilltrack/features/kanban/widgets/task_details_sheet.dart';
import 'package:skilltrack/features/kanban/widgets/task_stagnation_indicator.dart';

import '../../projects/fake_project_repository.dart';
import '../fake_repository.dart';

class _ActivityRepository extends FakeKanbanRepository {
  _ActivityRepository(KanbanTask task) : super(tasks: [task]);
  int activityLoads = 0;
  bool failResume = false;

  @override
  Future<void> addActivity(
    String taskId,
    String action, {
    Map<String, dynamic> oldValues = const {},
    Map<String, dynamic> newValues = const {},
  }) async {
    if (failResume) throw StateError('offline');
    await super.addActivity(
      taskId,
      action,
      oldValues: oldValues,
      newValues: newValues,
    );
  }

  @override
  Future<List<TaskActivity>> getTaskActivity(String taskId) async {
    activityLoads++;
    return [
      for (var index = 0; index < activityEvents.length; index++)
        TaskActivity(
          id: '$index',
          taskId: taskId,
          action: activityEvents[index].action,
          oldValues: activityEvents[index].oldValues,
          newValues: activityEvents[index].newValues,
          createdAt: DateTime.utc(2026, 10, 11),
        ),
    ];
  }
}

KanbanTask _task({int score = 80, bool stalled = true}) => sampleTask(
  '1',
  'Study',
  KanbanStatus.todo,
).copyWith(stagnationScore: score, isStalled: stalled);

Future<KanbanViewModel> _showDetails(
  WidgetTester tester,
  _ActivityRepository repository, {
  bool notificationWarning = false,
}) async {
  final model = KanbanViewModel(repository);
  await model.initialize('board-1');
  addTearDown(model.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: TaskDetailsSheet(
          taskId: '1',
          viewModel: model,
          onEdit: (_) {},
          showStalledWarning: notificationWarning,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return model;
}

void main() {
  test(
    'relative activity labels use elapsed time with singular and plural units',
    () {
      final now = DateTime.utc(2026, 10, 13, 12);
      for (final entry in {
        const Duration(seconds: 59): 'Just now',
        const Duration(minutes: 1): '1 minute ago',
        const Duration(minutes: 10): '10 minutes ago',
        const Duration(hours: 1): '1 hour ago',
        const Duration(hours: 3): '3 hours ago',
        const Duration(days: 1): '1 day ago',
        const Duration(days: 2): '2 days ago',
      }.entries) {
        expect(
          DateFormatter.relative(now.subtract(entry.key), now: now),
          entry.value,
        );
      }
      final future = now.add(const Duration(days: 1));
      expect(
        DateFormatter.relative(future, now: now),
        DateFormatter.short(future),
      );
    },
  );

  for (final entry in {
    0: 'Active',
    20: 'Active',
    40: 'Low risk',
    55: 'At risk',
    75: 'Stalled',
  }.entries) {
    testWidgets('details show ${entry.key}/100 as ${entry.value}', (
      tester,
    ) async {
      await _showDetails(
        tester,
        _ActivityRepository(_task(score: entry.key, stalled: false)),
      );
      expect(find.text('Stagnation'), findsOneWidget);
      expect(find.text('${entry.key}/100 · ${entry.value}'), findsOneWidget);
      expect(find.text('No activity recorded'), findsOneWidget);
      final progress = tester.widget<LinearProgressIndicator>(
        find.descendant(
          of: find.byType(TaskStagnationIndicator),
          matching: find.byType(LinearProgressIndicator),
        ),
      );
      expect(progress.value, entry.key / 100);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'stored stalled flag overrides a low score on cards and details',
    (tester) async {
      final task = _task(score: 20);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: KanbanTaskCard(task: task, onTap: () {}, onAction: (_) {}),
          ),
        ),
      );
      expect(find.text('Stalled'), findsOneWidget);
      await _showDetails(tester, _ActivityRepository(task));
      expect(find.text('20/100 · Stalled'), findsOneWidget);
      expect(find.text('This task was flagged as stalled.'), findsOneWidget);
    },
  );

  testWidgets(
    'refresh updates the current details from the stored task values',
    (tester) async {
      final repo = _ActivityRepository(_task(score: 55, stalled: false));
      final model = await _showDetails(tester, repo);
      expect(find.text('55/100 · At risk'), findsOneWidget);
      repo.stored[0] = repo.stored[0].copyWith(
        stagnationScore: 75,
        lastActivityAt: DateTime.now().toUtc(),
      );
      await model.refresh(showLoading: false);
      await tester.pumpAndSettle();
      expect(find.text('75/100 · Stalled'), findsOneWidget);
      expect(find.text('Last activity: Just now'), findsOneWidget);
      expect(find.text('55/100 · At risk'), findsNothing);
      expect(model.allTasks.single.isStalled, isFalse);
    },
  );

  for (final score in [0, 20, 40, 49, 50, 55, 69, 70, 75, 80, 100]) {
    testWidgets('card score $score follows the backend risk threshold', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: KanbanTaskCard(
              task: _task(score: score, stalled: false),
              onTap: () {},
              onAction: (_) {},
            ),
          ),
        ),
      );
      expect(
        find.byType(TaskStagnationIndicator),
        score >= 50 ? findsOneWidget : findsNothing,
      );
      expect(
        find.text(score >= 70 ? 'Stalled' : 'At risk'),
        score >= 50 ? findsOneWidget : findsNothing,
      );
      expect(find.textContaining('/100'), findsNothing);
    });
  }

  testWidgets('stalled card has accessible score and keeps taps and actions', (
    tester,
  ) async {
    var taps = 0;
    TaskCardAction? action;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: KanbanTaskCard(
            task: _task(),
            onTap: () => taps++,
            onAction: (value) => action = value,
          ),
        ),
      ),
    );
    expect(find.text('Stalled'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Task stalled, stagnation score 80 out of 100'),
      findsOneWidget,
    );
    await tester.tap(find.text('Stalled'));
    expect(taps, 1);
    await tester.tap(find.byTooltip('Task actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move to In Progress'));
    expect(action, TaskCardAction.inProgress);
  });

  for (final task in [
    _task().copyWith(status: KanbanStatus.completed),
    _task().copyWith(isArchived: true),
  ]) {
    testWidgets(
      '${task.isArchived ? 'archived' : 'completed'} task suppresses stale risk warnings',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: KanbanTaskCard(task: task, onTap: () {}, onAction: (_) {}),
            ),
          ),
        );
        expect(find.byType(TaskStagnationIndicator), findsNothing);
        await _showDetails(
          tester,
          _ActivityRepository(task),
          notificationWarning: true,
        );
        expect(find.text('This task was flagged as stalled.'), findsNothing);
        expect(find.text('Stagnation'), findsNothing);
      },
    );
  }

  testWidgets(
    'Task Details uses the latest stored score and local activity time',
    (tester) async {
      final activity = DateTime.now().toUtc().subtract(
        const Duration(days: 2, minutes: 1),
      );
      await _showDetails(
        tester,
        _ActivityRepository(_task().copyWith(lastActivityAt: activity)),
      );
      expect(find.text('Stagnation'), findsOneWidget);
      expect(find.text('80/100 · Stalled'), findsOneWidget);
      expect(find.text('This task was flagged as stalled.'), findsOneWidget);
      final local = activity.toLocal();
      final time = MaterialLocalizations.of(
        tester.element(find.byType(TaskDetailsSheet)),
      ).formatTimeOfDay(TimeOfDay.fromDateTime(local));
      expect(
        find.byTooltip('${DateFormatter.short(local)} · $time'),
        findsOneWidget,
      );
      expect(find.text('Last activity: 2 days ago'), findsOneWidget);
      final progress = tester.widget<LinearProgressIndicator>(
        find.descendant(
          of: find.byType(TaskStagnationIndicator),
          matching: find.byType(LinearProgressIndicator),
        ),
      );
      expect(progress.value, .8);
      expect(
        progress.color,
        Theme.of(
          tester.element(find.byType(TaskDetailsSheet)),
        ).colorScheme.error,
      );
    },
  );

  testWidgets('at-risk details handle an unavailable activity time', (
    tester,
  ) async {
    await _showDetails(
      tester,
      _ActivityRepository(_task(score: 60, stalled: false)),
    );
    expect(find.text('60/100 · At risk'), findsOneWidget);
    expect(find.text('No activity recorded'), findsOneWidget);
    expect(find.text('This task was flagged as stalled.'), findsNothing);
    final progress = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(progress.value, .6);
    expect(progress.color, const Color(0xFFAE6800));
  });

  testWidgets('notification warning remains available without a stored flag', (
    tester,
  ) async {
    await _showDetails(
      tester,
      _ActivityRepository(_task(score: 0, stalled: false)),
      notificationWarning: true,
    );
    expect(find.text('This task was flagged as stalled.'), findsOneWidget);
    expect(find.text('0/100 · Active'), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Resume Task'))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('resume hides only the session warning and refreshes activity', (
    tester,
  ) async {
    final repository = _ActivityRepository(_task());
    final model = await _showDetails(
      tester,
      repository,
      notificationWarning: true,
    );
    expect(find.text('This task was flagged as stalled.'), findsOneWidget);
    await tester.tap(find.text('Resume Task'));
    await tester.pumpAndSettle();
    expect(repository.activityEvents.single.action, 'resumed');
    expect(repository.activityEvents.single.taskId, '1');
    expect(repository.activityLoads, 2);
    expect(find.text('This task was flagged as stalled.'), findsNothing);
    expect(find.text('80/100 · Stalled'), findsOneWidget);
    expect(model.allTasks.single.isStalled, isTrue);
    expect(repository.stored.single.stagnationScore, 80);
    await tester.scrollUntilVisible(
      find.text('Activity'),
      150,
      scrollable: find
          .descendant(
            of: find.byType(TaskDetailsSheet),
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is Scrollable &&
                  widget.axisDirection == AxisDirection.down,
            ),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(find.text('Task resumed'), findsOneWidget);
  });

  testWidgets('failed resume retains the warning and stored stagnation', (
    tester,
  ) async {
    final repository = _ActivityRepository(_task())..failResume = true;
    final model = await _showDetails(tester, repository);
    await tester.tap(find.text('Resume Task'));
    await tester.pumpAndSettle();
    expect(
      find.text('Unable to resume the task. Please try again.'),
      findsOneWidget,
    );
    expect(find.text('This task was flagged as stalled.'), findsOneWidget);
    expect(repository.activityEvents, isEmpty);
    expect(repository.activityLoads, 1);
    expect(model.allTasks.single.isStalled, isTrue);
  });

  testWidgets('risk card fits a narrow viewport with enlarged text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.6)),
          child: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(24),
              child: KanbanTaskCard(
                task: _task(),
                onTap: () {},
                onAction: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.text('Stalled'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('opening a stalled task from its board supports Resume', (
    tester,
  ) async {
    final repository = _ActivityRepository(_task());
    await tester.pumpWidget(
      SkillTrackApp(
        projectRepository: FakeProjectRepository(
          items: [sampleProject('project', 'Flutter', boardId: 'board-1')],
        ),
        kanbanRepository: repository,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Flutter'));
    await tester.pumpAndSettle();
    expect(find.text('Stalled'), findsOneWidget);
    await tester.tap(find.text('Study'));
    await tester.pumpAndSettle();
    expect(find.text('This task was flagged as stalled.'), findsOneWidget);
    await tester.tap(find.text('Resume Task'));
    await tester.pumpAndSettle();
    expect(repository.activityEvents.single.action, 'resumed');
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Study'));
    await tester.pumpAndSettle();
    expect(find.text('This task was flagged as stalled.'), findsOneWidget);
    expect(repository.stored.single.isStalled, isTrue);
  });
}
