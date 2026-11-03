import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skilltrack/core/errors/app_exception.dart';
import 'package:skilltrack/features/kanban/models/kanban_status.dart';
import 'package:skilltrack/features/kanban/models/kanban_task.dart';
import 'package:skilltrack/features/kanban/viewmodels/kanban_view_model.dart';
import 'package:skilltrack/features/kanban/widgets/task_form_sheet.dart';
import '../fake_repository.dart';

class _SaveRepository extends FakeKanbanRepository {
  _SaveRepository({super.tasks});
  int creates = 0, updates = 0;
  Object? failure = const AppException(AppErrorMessages.taskSetupIncomplete);
  Completer<void>? pending;
  @override
  Future<KanbanTask> createTask(KanbanTask task) async {
    creates++;
    await pending?.future;
    if (failure != null) throw failure!;
    return super.createTask(task);
  }

  @override
  Future<KanbanTask> updateTask(KanbanTask task) async {
    updates++;
    if (failure != null) throw failure!;
    return super.updateTask(task);
  }
}

Future<KanbanViewModel> _showForm(
  WidgetTester tester,
  _SaveRepository repo, {
  KanbanTask? task,
}) async {
  final model = KanbanViewModel(repo);
  await model.initialize('board-1');
  await tester.pumpWidget(
    MaterialApp(
      initialRoute: '/form',
      routes: {
        '/': (_) => const Scaffold(body: Text('Board')),
        '/form': (_) => TaskFormSheet(viewModel: model, task: task),
      },
    ),
  );
  await tester.pumpAndSettle();
  return model;
}

void main() {
  testWidgets('empty title validates without sending an insert', (
    tester,
  ) async {
    final repo = _SaveRepository();
    final model = await _showForm(tester, repo);
    await tester.tap(find.byKey(const Key('save-task-button')));
    await tester.pumpAndSettle();
    expect(find.text('Task title is required'), findsOneWidget);
    expect(repo.creates, 0);
    await tester.pumpWidget(const SizedBox());
    model.dispose();
  });
  testWidgets(
    'pending save blocks duplicate taps, failure is visible and retry retains input',
    (tester) async {
      final repo = _SaveRepository()..pending = Completer<void>();
      final model = await _showForm(tester, repo);
      await tester.enterText(
        find.byKey(const Key('task-title-field')),
        'Keep my title',
      );
      tester.testTextInput.hide();
      await tester.pump();
      final button = find.byKey(const Key('save-task-button'));
      await tester.tap(button);
      await tester.tap(button);
      await tester.pump();
      expect(repo.creates, 1);
      expect(tester.widget<FilledButton>(button).onPressed, isNull);
      expect(find.text('Creating…'), findsOneWidget);
      repo.pending!.complete();
      await tester.pumpAndSettle();
      expect(find.text(AppErrorMessages.taskSetupIncomplete), findsOneWidget);
      expect(find.byType(TaskFormSheet), findsOneWidget);
      expect(
        tester
            .widget<TextFormField>(find.byKey(const Key('task-title-field')))
            .controller!
            .text,
        'Keep my title',
      );
      expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
      expect(repo.stored, isEmpty);
      repo.failure = null;
      repo.pending = null;
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(repo.creates, 2);
      expect(repo.stored.single.title, 'Keep my title');
      expect(find.text(AppErrorMessages.taskSetupIncomplete), findsNothing);
      expect(find.text('Board'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );
  testWidgets(
    'unexpected save failure is displayed without discarding form input',
    (tester) async {
      final repo = _SaveRepository()..failure = StateError('offline');
      final model = await _showForm(tester, repo);
      await tester.enterText(
        find.byKey(const Key('task-title-field')),
        'Keep this',
      );
      tester.testTextInput.hide();
      await tester.pump();
      await tester.tap(find.byKey(const Key('save-task-button')));
      await tester.pumpAndSettle();
      expect(find.text(AppErrorMessages.requestFailed), findsOneWidget);
      expect(find.byType(TaskFormSheet), findsOneWidget);
      expect(repo.creates, 1);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );
  testWidgets('edit failure stays on the form and preserves the stored task', (
    tester,
  ) async {
    final task = sampleTask(
      't',
      'Original',
      KanbanStatus.todo,
      deadline: DateTime.utc(2026, 11, 3, 10),
    ).copyWith(deadlineHasTime: true);
    final repo = _SaveRepository(tasks: [task]);
    final model = await _showForm(tester, repo, task: task);
    await tester.enterText(find.byKey(const Key('task-title-field')), 'Edited');
    tester.testTextInput.hide();
    await tester.pump();
    await tester.tap(find.byKey(const Key('save-task-button')));
    await tester.pumpAndSettle();
    expect(find.text(AppErrorMessages.taskSetupIncomplete), findsOneWidget);
    expect(repo.updates, 1);
    expect(repo.stored.single, task);
    expect(
      tester
          .widget<TextFormField>(find.byKey(const Key('task-title-field')))
          .controller!
          .text,
      'Edited',
    );
    await tester.pumpWidget(const SizedBox());
    model.dispose();
  });
}
