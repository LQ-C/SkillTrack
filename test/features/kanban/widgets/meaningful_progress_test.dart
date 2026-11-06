import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skilltrack/app/app_theme.dart';
import 'package:skilltrack/core/constants/app_constants.dart';
import 'package:skilltrack/core/errors/app_exception.dart';
import 'package:skilltrack/features/kanban/models/kanban_status.dart';
import 'package:skilltrack/features/kanban/models/task_activity.dart';
import 'package:skilltrack/features/kanban/viewmodels/kanban_view_model.dart';
import 'package:skilltrack/features/kanban/widgets/task_details_sheet.dart';
import 'package:skilltrack/features/kanban/widgets/activity_timeline.dart';
import '../fake_repository.dart';

class _ProgressRepository extends FakeKanbanRepository {
  _ProgressRepository()
    : super(
        tasks: [
          sampleTask('t', 'Task title', KanbanStatus.inProgress).copyWith(
            isStalled: true,
            stagnationScore: 80,
            stalledAt: DateTime.utc(2026, 10, 1),
          ),
        ],
      );
  Completer<void>? pending;
  int attempts = 0;
  @override
  Future<void> addProgressUpdate(
    String taskId,
    String text, {
    required String requestId,
  }) async {
    attempts++;
    await pending?.future;
    await super.addProgressUpdate(taskId, text, requestId: requestId);
  }

  @override
  Future<List<TaskActivity>> getTaskActivity(String taskId) async => [
    for (var i = 0; i < activityEvents.length; i++)
      TaskActivity(
        id: 'activity-$i',
        taskId: taskId,
        action: activityEvents[i].action,
        oldValues: activityEvents[i].oldValues,
        newValues: activityEvents[i].newValues,
        createdAt: DateTime.utc(2026, 11, 3, 0, i),
      ),
  ];
}

Future<KanbanViewModel> _model(_ProgressRepository repo) async {
  final model = KanbanViewModel(repo);
  await model.initialize('board-1');
  return model;
}

Future<void> _details(WidgetTester tester, KanbanViewModel model) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light,
      home: Scaffold(
        appBar: AppBar(title: const Text('Task Details')),
        body: TaskDetailsSheet(
          taskId: 't',
          viewModel: model,
          onEdit: (_) {},
          fullScreen: true,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(
    find.byKey(const Key('add-progress-update')),
    250,
    scrollable: find
        .descendant(
          of: find.byType(TaskDetailsSheet),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('add-progress-update')));
  await tester.pumpAndSettle();
}

void main() {
  test(
    'shared progress validation trims text and enforces 1000 characters',
    () {
      expect(
        TaskActivity.validateProgressText(' \t\n'),
        AppErrorMessages.progressUpdateRequired,
      );
      expect(
        TaskActivity.validateProgressText(
          'x' * (AppLimits.maxProgressUpdateLength + 1),
        ),
        AppErrorMessages.progressUpdateTooLong,
      );
      expect(
        TaskActivity.validateProgressText(
          '  ${'x' * AppLimits.maxProgressUpdateLength}  ',
        ),
        isNull,
      );
    },
  );
  test(
    'ViewModel rejects invalid progress without writing, advances activity only after success',
    () async {
      final repo = _ProgressRepository();
      final model = await _model(repo);
      addTearDown(model.dispose);
      for (final text in ['  ', 'x' * 1001]) {
        expect(await model.addProgressUpdate('t', text), isFalse);
      }
      expect(repo.attempts, 0);
      expect(model.activityVersion, 0);
      repo.failProgress = true;
      expect(await model.addProgressUpdate('t', 'Implemented API'), isFalse);
      expect(model.allTasks.single.isStalled, isTrue);
      expect(model.activityVersion, 0);
      expect(model.errorMessage, AppErrorMessages.saveProgressUpdateFailed);
      repo.failProgress = false;
      expect(await model.addProgressUpdate('t', '  Implemented API  '), isTrue);
      expect(repo.progressRequestIds.toSet(), hasLength(1));
      expect(
        repo.activityEvents.single.newValues['progress_text'],
        'Implemented API',
      );
      expect(model.activityVersion, 1);
      expect(model.allTasks.single.isStalled, isFalse);
      expect(model.allTasks.single.title, 'Task title');
    },
  );
  test(
    'pending progress blocks duplicate callbacks; a lost response retries one saved log',
    () async {
      final repo = _ProgressRepository()
        ..pending = Completer<void>()
        ..loseProgressResponseOnce = true;
      final model = await _model(repo);
      addTearDown(model.dispose);
      final pending = model.addProgressUpdate('t', 'Done API');
      expect(model.isSaving, isTrue);
      expect(await model.addProgressUpdate('t', 'Done API'), isFalse);
      expect(repo.attempts, 1);
      repo.pending!.complete();
      expect(await pending, isFalse);
      expect(repo.activityEvents, hasLength(1));
      repo.pending = null;
      expect(await model.addProgressUpdate('t', 'Done API'), isTrue);
      expect(repo.activityEvents, hasLength(1));
      expect(repo.progressRequestIds.toSet(), hasLength(1));
    },
  );
  test('changed progress text after failure gets a new request ID', () async {
    final repo = _ProgressRepository()..failProgress = true;
    final model = await _model(repo);
    addTearDown(model.dispose);
    await model.addProgressUpdate('t', 'Before');
    repo.failProgress = false;
    expect(await model.addProgressUpdate('t', 'After'), isTrue);
    expect(repo.progressRequestIds.toSet(), hasLength(2));
  });
  test('archived and missing tasks cannot save progress', () async {
    final repo = _ProgressRepository();
    final model = await _model(repo);
    addTearDown(model.dispose);
    expect(await model.addProgressUpdate('missing', 'Work'), isFalse);
    expect(await model.archiveTask('t'), isTrue);
    expect(await model.addProgressUpdate('t', 'Work'), isFalse);
    expect(repo.attempts, 0);
  });
  testWidgets(
    'timeline distinguishes explicit progress from ordinary description editing',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ActivityTimeline(
              activities: [
                TaskActivity(
                  id: '1',
                  taskId: 't',
                  action: 'updated',
                  oldValues: {},
                  newValues: {
                    'change': 'progress_update',
                    'progress_text': 'Completed API tests',
                  },
                  createdAt: DateTime.utc(2026, 11, 3, 10),
                ),
                TaskActivity(
                  id: '2',
                  taskId: 't',
                  action: 'updated',
                  oldValues: {},
                  newValues: {'title': 'New title'},
                  createdAt: DateTime.utc(2026, 11, 3, 9),
                ),
              ],
            ),
          ),
        ),
      );
      expect(find.text('Progress update'), findsOneWidget);
      expect(find.text('Completed API tests'), findsOneWidget);
      expect(find.text('Task updated'), findsOneWidget);
      expect(find.text('Title: New title'), findsOneWidget);
    },
  );
  testWidgets(
    'dialog validates, retains failed input, blocks double submit and refreshes activity',
    (tester) async {
      final repo = _ProgressRepository();
      final model = await _model(repo);
      addTearDown(model.dispose);
      await _details(tester, model);
      final save = find.byKey(const Key('save-progress-update'));
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(
        find.text(AppErrorMessages.progressUpdateRequired),
        findsOneWidget,
      );
      expect(repo.attempts, 0);
      final input = find.byKey(const Key('progress-update-text'));
      await tester.enterText(input, 'x' * 1001);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(find.text(AppErrorMessages.progressUpdateTooLong), findsOneWidget);
      expect(repo.attempts, 0);
      await tester.enterText(input, '  Verified the API  ');
      repo.pending = Completer<void>();
      repo.failProgress = true;
      await tester.tap(save);
      await tester.tap(save);
      await tester.pump();
      expect(repo.attempts, 1);
      expect(tester.widget<FilledButton>(save).onPressed, isNull);
      expect(tester.widget<TextFormField>(input).enabled, isFalse);
      repo.pending!.complete();
      await tester.pumpAndSettle();
      expect(
        find.text(AppErrorMessages.saveProgressUpdateFailed),
        findsOneWidget,
      );
      expect(
        tester.widget<TextFormField>(input).controller!.text,
        '  Verified the API  ',
      );
      expect(find.byType(TaskDetailsSheet), findsOneWidget);
      repo.pending = null;
      repo.failProgress = false;
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(TaskDetailsSheet), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Verified the API'),
        150,
        scrollable: find
            .descendant(
              of: find.byType(TaskDetailsSheet),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(find.text('Verified the API'), findsOneWidget);
      expect(repo.activityEvents, hasLength(1));
      expect(repo.progressRequestIds.toSet(), hasLength(1));
    },
  );
  testWidgets('cancelling the progress dialog saves nothing', (tester) async {
    final repo = _ProgressRepository();
    final model = await _model(repo);
    addTearDown(model.dispose);
    await _details(tester, model);
    await tester.enterText(
      find.byKey(const Key('progress-update-text')),
      'Draft progress',
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(repo.attempts, 0);
    expect(model.allTasks.single.isStalled, isTrue);
  });
}
