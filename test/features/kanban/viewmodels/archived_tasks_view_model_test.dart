import 'dart:async';
import 'package:skilltrack/features/kanban/models/kanban_task.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skilltrack/features/kanban/models/kanban_status.dart';
import 'package:skilltrack/features/kanban/models/task_tag.dart';
import 'package:skilltrack/features/kanban/viewmodels/archived_tasks_view_model.dart';

import '../fake_repository.dart';

void main() {
  test('archive refresh is exclusive and failure permits retry', () async {
    final repo = _ArchivedLoadGate();
    final model = ArchivedTasksViewModel(repo);
    addTearDown(model.dispose);
    final load = model.loadArchivedTasks('board-1');
    await model.refresh();
    await model.loadArchivedTasks('board-1');
    expect(repo.loadCalls, 1);
    expect(model.isLoading, isTrue);
    repo.gate!.completeError(StateError('offline'));
    await load;
    expect(model.isLoading, isFalse);
    repo.gate = null;
    await model.refresh();
    expect(repo.loadCalls, 2);
    expect(model.errorMessage, isNull);
  });

  test('loads only archived tasks from the selected board', () async {
    final repository = FakeKanbanRepository(
      tasks: [
        sampleTask(
          '1',
          'Archived',
          KanbanStatus.todo,
        ).copyWith(isArchived: true),
        sampleTask('2', 'Active', KanbanStatus.todo),
        sampleTask(
          '3',
          'Other board',
          KanbanStatus.completed,
        ).copyWith(boardId: 'board-2', isArchived: true),
      ],
    );
    final model = ArchivedTasksViewModel(repository);
    await model.loadArchivedTasks('board-1');
    expect(model.archivedTasks.map((task) => task.id), ['1']);
    expect(
      () => model.archivedTasks.add(repository.stored.first),
      throwsUnsupportedError,
    );
    model.dispose();
  });

  test('search matches titles, descriptions, and tags', () async {
    final tag = TaskTag(
      id: 'tag-1',
      ownerId: 'user-1',
      name: 'Revision',
      colorHex: '#675F9C',
    );
    final repository = FakeKanbanRepository(
      tasks: [
        sampleTask(
          '1',
          'Study',
          KanbanStatus.todo,
          tags: [tag],
        ).copyWith(isArchived: true),
        sampleTask(
          '2',
          'Design',
          KanbanStatus.inProgress,
        ).copyWith(isArchived: true),
      ],
    );
    final model = ArchivedTasksViewModel(repository);
    await model.loadArchivedTasks('board-1');
    model.setSearchQuery('study');
    expect(model.visibleTasks.single.id, '1');
    model.setSearchQuery('Description for Design');
    expect(model.visibleTasks.single.id, '2');
    model.setSearchQuery('revision');
    expect(model.visibleTasks.single.id, '1');
    model.setSearchQuery('missing');
    expect(model.isSearchEmpty, true);
    model.dispose();
  });

  test(
    'restoring a completed task preserves status and completed_at',
    () async {
      final task = sampleTask(
        '1',
        'Done',
        KanbanStatus.completed,
        order: 3,
      ).copyWith(isArchived: true);
      final repository = FakeKanbanRepository(tasks: [task]);
      final model = ArchivedTasksViewModel(repository);
      await model.loadArchivedTasks('board-1');
      expect(await model.restoreTask('1'), true);
      expect(model.isEmpty, true);
      expect(model.feedbackMessage, 'Task restored');
      final restored = repository.stored.single;
      expect(restored.isArchived, false);
      expect(restored.status, KanbanStatus.completed);
      expect(restored.completedAt, task.completedAt);
      expect(restored.sortOrder, 3);
      model.dispose();
    },
  );

  test('restoring an incomplete task leaves completed_at null', () async {
    final repository = FakeKanbanRepository(
      tasks: [
        sampleTask(
          '1',
          'Work',
          KanbanStatus.inProgress,
        ).copyWith(isArchived: true),
      ],
    );
    final model = ArchivedTasksViewModel(repository);
    await model.loadArchivedTasks('board-1');
    expect(await model.restoreTask('1'), true);
    expect(repository.stored.single.status, KanbanStatus.inProgress);
    expect(repository.stored.single.completedAt, isNull);
    model.dispose();
  });

  test('restore failure retains the archived task', () async {
    final repository = FakeKanbanRepository(
      tasks: [
        sampleTask('1', 'Work', KanbanStatus.todo).copyWith(isArchived: true),
      ],
    )..failArchive = true;
    final model = ArchivedTasksViewModel(repository);
    await model.loadArchivedTasks('board-1');
    expect(await model.restoreTask('1'), false);
    expect(model.archivedTasks.single.id, '1');
    expect(repository.stored.single.isArchived, true);
    expect(model.errorMessage, isNotNull);
    model.dispose();
  });

  test('restore all affects only selected board', () async {
    final repository = FakeKanbanRepository(
      tasks: [
        sampleTask('1', 'One', KanbanStatus.todo).copyWith(isArchived: true),
        sampleTask(
          '2',
          'Two',
          KanbanStatus.completed,
        ).copyWith(isArchived: true),
        sampleTask(
          '3',
          'Other',
          KanbanStatus.todo,
        ).copyWith(boardId: 'board-2', isArchived: true),
      ],
    );
    final model = ArchivedTasksViewModel(repository);
    await model.loadArchivedTasks('board-1');
    expect(await model.restoreAllTasks(), true);
    expect(model.isEmpty, true);
    expect(model.feedbackMessage, 'All tasks restored');
    expect(repository.stored.where((task) => task.isArchived).single.id, '3');
    model.dispose();
  });

  test(
    'partial restore all reports failures and reloads remaining tasks',
    () async {
      final repository = FakeKanbanRepository(
        tasks: [
          sampleTask('1', 'One', KanbanStatus.todo).copyWith(isArchived: true),
          sampleTask('2', 'Two', KanbanStatus.todo).copyWith(isArchived: true),
        ],
      )..failArchiveIds.add('2');
      final model = ArchivedTasksViewModel(repository);
      await model.loadArchivedTasks('board-1');
      expect(await model.restoreAllTasks(), false);
      expect(model.archivedTasks.map((task) => task.id), ['2']);
      expect(model.errorMessage, contains('1 of 2'));
      model.dispose();
    },
  );

  test('empty and loading error states recover with retry', () async {
    final repository = FakeKanbanRepository();
    final model = ArchivedTasksViewModel(repository);
    await model.loadArchivedTasks('board-1');
    expect(model.isEmpty, true);
    repository.failLoad = true;
    await model.refresh();
    expect(model.errorMessage, 'Unable to load archived tasks');
    repository.failLoad = false;
    await model.retry();
    expect(model.errorMessage, null);
    expect(model.isEmpty, true);
    model.dispose();
  });

  test('permanent delete removes a task only after success', () async {
    final repository = FakeKanbanRepository(
      tasks: [
        sampleTask('1', 'Old', KanbanStatus.todo).copyWith(isArchived: true),
      ],
    )..failDelete = true;
    final model = ArchivedTasksViewModel(repository);
    await model.loadArchivedTasks('board-1');
    expect(await model.deleteTaskPermanently('1'), false);
    expect(model.archivedTasks.length, 1);
    repository.failDelete = false;
    expect(await model.deleteTaskPermanently('1'), true);
    expect(model.archivedTasks, isEmpty);
    expect(repository.stored, isEmpty);
    model.dispose();
  });
}

class _ArchivedLoadGate extends FakeKanbanRepository {
  Completer<void>? gate = Completer<void>();
  int loadCalls = 0;

  @override
  Future<List<KanbanTask>> getArchivedTasks(String boardId) async {
    loadCalls++;
    await gate?.future;
    return super.getArchivedTasks(boardId);
  }
}
