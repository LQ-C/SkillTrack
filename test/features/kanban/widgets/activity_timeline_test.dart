import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skilltrack/features/kanban/models/kanban_status.dart';
import 'package:skilltrack/features/kanban/models/task_activity.dart';
import 'package:skilltrack/features/kanban/viewmodels/kanban_view_model.dart';
import 'package:skilltrack/features/kanban/widgets/activity_timeline.dart';
import 'package:skilltrack/features/kanban/widgets/task_details_sheet.dart';

import '../fake_repository.dart';

TaskActivity record(
  String id,
  int minute,
  String action, {
  Map<String, dynamic> oldValues = const {},
  Map<String, dynamic> newValues = const {},
}) => TaskActivity(
  id: id,
  taskId: '1',
  action: action,
  oldValues: oldValues,
  newValues: newValues,
  createdAt: DateTime(2026, 10, 6, 11, minute),
);

Future<void> showTimeline(
  WidgetTester tester,
  List<TaskActivity> activities,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ListView(children: [ActivityTimeline(activities: activities)]),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('empty activity has a clear message', (tester) async {
    await showTimeline(tester, []);
    expect(find.text('Activity'), findsOneWidget);
    expect(find.text('No activity recorded yet.'), findsOneWidget);
    expect(find.byKey(const Key('activity-toggle')), findsNothing);
  });

  testWidgets('cross-status activity names both statuses', (tester) async {
    await showTimeline(tester, [
      record(
        'move-1',
        1,
        'moved',
        oldValues: {'status': 'todo', 'position': 1},
        newValues: {'status': 'in_progress', 'position': 1},
      ),
    ]);
    expect(find.text('Task moved from To-Do to In Progress'), findsOneWidget);
  });

  testWidgets('resume activity has a readable label', (tester) async {
    await showTimeline(tester, [record('resume', 1, 'resumed')]);
    expect(find.text('Task resumed'), findsOneWidget);
  });

  testWidgets('one to three activities show all without a toggle', (
    tester,
  ) async {
    for (var count = 1; count <= 3; count++) {
      final activities = [
        for (var i = 0; i < count; i++) record('$i', i, 'created'),
      ];
      await showTimeline(tester, activities);
      for (final activity in activities) {
        expect(find.byKey(ValueKey(activity.id)), findsOneWidget);
      }
      expect(find.byKey(const Key('activity-toggle')), findsNothing);
    }
  });

  testWidgets('four records start with latest three and singular count', (
    tester,
  ) async {
    final activities = [
      record('oldest', 1, 'created'),
      record('latest', 4, 'checklist_updated'),
      record('second', 3, 'moved', newValues: {'status': 'in_progress'}),
      record('third', 2, 'updated'),
    ];
    await showTimeline(tester, activities);
    expect(find.byKey(const ValueKey('oldest')), findsNothing);
    expect(find.text('Show 1 more activity'), findsOneWidget);
    final top = tester.getTopLeft(find.byKey(const ValueKey('latest'))).dy;
    final next = tester.getTopLeft(find.byKey(const ValueKey('second'))).dy;
    final third = tester.getTopLeft(find.byKey(const ValueKey('third'))).dy;
    expect(top, lessThan(next));
    expect(next, lessThan(third));
    expect(find.text('Checklist updated'), findsOneWidget);
    expect(find.text('Moved to In Progress'), findsOneWidget);
    expect(find.text('06/10/2026 · 11:04 AM'), findsOneWidget);

    await tester.tap(find.text('Show 1 more activity'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('oldest')), findsOneWidget);
    expect(find.text('Show less'), findsOneWidget);

    await tester.tap(find.text('Show less'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('oldest')), findsNothing);
    expect(find.text('Activity'), findsOneWidget);
  });

  testWidgets('plural count and readable labels for stored actions', (
    tester,
  ) async {
    final actions = [
      'created',
      'updated',
      'moved',
      'completed',
      'reopened',
      'checklist_updated',
      'tag_added',
      'tag_removed',
      'attachment_added',
      'attachment_removed',
      'archived',
      'restored',
    ];
    await showTimeline(tester, [
      for (var i = 0; i < actions.length; i++)
        record('$i', i, actions[i], newValues: {'status': 'todo'}),
    ]);
    expect(find.text('Show 9 more activities'), findsOneWidget);
    await tester.tap(find.text('Show 9 more activities'));
    await tester.pumpAndSettle();
    for (final label in [
      'Task created',
      'Task updated',
      'Moved to To-Do',
      'Task completed',
      'Task reopened',
      'Checklist updated',
      'Tag added',
      'Tag removed',
      'Attachment added',
      'Attachment removed',
      'Task archived',
      'Task restored',
    ]) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('checklist_updated'), findsNothing);
    expect(find.text('tag_added'), findsNothing);
  });

  testWidgets('updated list preserves expansion and hides toggle at three', (
    tester,
  ) async {
    var activities = [for (var i = 0; i < 5; i++) record('$i', i, 'created')];
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return ActivityTimeline(activities: activities);
            },
          ),
        ),
      ),
    );
    await tester.tap(find.text('Show 2 more activities'));
    await tester.pumpAndSettle();
    update(() => activities = [...activities, record('new', 8, 'updated')]);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('new')), findsOneWidget);
    expect(find.byKey(const ValueKey('0')), findsOneWidget);
    expect(find.text('Show less'), findsOneWidget);

    update(
      () => activities = [record('new', 8, 'updated'), ...activities.take(2)],
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('activity-toggle')), findsNothing);
    expect(find.byKey(const ValueKey('new')), findsOneWidget);
  });

  testWidgets('expanding inside Task Details stays on the same page', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = _ActivityRepository([
      for (var i = 0; i < 4; i++) record('$i', i, 'updated'),
    ]);
    final viewModel = KanbanViewModel(repository);
    await viewModel.initialize('board-1');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TaskDetailsSheet(
            taskId: '1',
            viewModel: viewModel,
            onEdit: (_) {},
            fullScreen: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Show 1 more activity'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show 1 more activity'));
    await tester.pumpAndSettle();
    expect(find.text('Show less'), findsOneWidget);
    expect(find.byType(TaskDetailsSheet), findsOneWidget);
  });
}

class _ActivityRepository extends FakeKanbanRepository {
  _ActivityRepository(this.records)
    : super(tasks: [sampleTask('1', 'Plan', KanbanStatus.todo)]);

  final List<TaskActivity> records;

  @override
  Future<List<TaskActivity>> getTaskActivity(String taskId) async => records;
}
