import 'package:flutter_test/flutter_test.dart';
import 'package:skilltrack/features/kanban/models/kanban_filter.dart';
import 'package:skilltrack/features/kanban/models/kanban_sort.dart';
import 'package:skilltrack/features/kanban/models/kanban_status.dart';
import 'package:skilltrack/features/kanban/models/task_checklist_item.dart';
import 'package:skilltrack/features/kanban/models/task_priority.dart';
import 'package:skilltrack/features/kanban/models/task_tag.dart';
import 'package:skilltrack/features/kanban/viewmodels/kanban_view_model.dart';

import '../fake_repository.dart';

void main() {
  group('KanbanViewModel', () {
    test('loads tasks and derives progress', () async {
      final repo = FakeKanbanRepository(
        tasks: [
          sampleTask('1', 'Plan', KanbanStatus.todo),
          sampleTask('2', 'Build', KanbanStatus.completed),
        ],
      );
      final model = KanbanViewModel(repo);
      await model.initialize();
      expect(model.isLoading, false);
      expect(model.totalTaskCount, 2);
      expect(model.completedTaskCount, 1);
      expect(model.projectProgress, .5);
      expect(model.projectProgressPercentage, 50);
      expect(() => model.allTasks.clear(), throwsUnsupportedError);
      model.dispose();
    });

    test('empty board has zero progress', () async {
      final model = KanbanViewModel(FakeKanbanRepository());
      await model.initialize();
      expect(model.isBoardEmpty, true);
      expect(model.projectProgress, 0);
      model.dispose();
    });

    test(
      'no project board shows an empty board without a load error',
      () async {
        final model = KanbanViewModel(FakeKanbanRepository(noBoard: true));
        await model.initialize();
        expect(model.boardId, null);
        expect(model.isBoardEmpty, true);
        expect(model.projectProgressPercentage, 0);
        expect(model.errorMessage, null);
        model.dispose();
      },
    );

    test('loading failure exposes an error and retry recovers', () async {
      final repo = FakeKanbanRepository(failLoad: true);
      final model = KanbanViewModel(repo);
      await model.initialize();
      expect(model.errorMessage, contains('offline'));
      repo.failLoad = false;
      await model.retry();
      expect(model.errorMessage, null);
      model.dispose();
    });

    test('validates title and creates and updates tasks', () async {
      final model = KanbanViewModel(FakeKanbanRepository());
      await model.initialize();
      expect(await model.createTask(title: '  '), false);
      expect(model.titleError, isNotNull);
      expect(await model.createTask(title: 'Research'), true);
      final task = model.allTasks.single;
      expect(task.title, 'Research');
      expect(
        await model.updateTask(
          task,
          title: 'Design',
          description: 'New',
          status: KanbanStatus.inProgress,
          priority: TaskPriority.high,
        ),
        true,
      );
      expect(model.allTasks.single.title, 'Design');
      model.dispose();
    });

    test('completion and reopening update timestamps and progress', () async {
      final model = KanbanViewModel(
        FakeKanbanRepository(
          tasks: [sampleTask('1', 'Plan', KanbanStatus.todo)],
        ),
      );
      await model.initialize();
      expect(await model.completeTask('1'), true);
      expect(model.allTasks.single.completedAt, isNotNull);
      expect(model.projectProgress, 1);
      expect(model.feedbackMessage, 'Task marked as completed');
      expect(await model.undoLastAction(), true);
      expect(model.allTasks.single.status, KanbanStatus.todo);
      expect(await model.completeTask('1'), true);
      expect(await model.reopenTask('1', KanbanStatus.todo), true);
      expect(model.allTasks.single.completedAt, null);
      expect(model.projectProgress, 0);
      expect(model.feedbackMessage, 'Task reopened');
      model.dispose();
    });

    test('silent refresh updates tasks without showing a loading skeleton', () async {
      final repository = FakeKanbanRepository(
        tasks: [sampleTask('1', 'First', KanbanStatus.todo)],
      );
      final model = KanbanViewModel(repository);
      await model.initialize();
      final loadingStates = <bool>[];
      model.addListener(() => loadingStates.add(model.isLoading));
      repository.stored.add(sampleTask('2', 'Restored', KanbanStatus.todo));
      await model.refresh(showLoading: false);
      expect(model.totalTaskCount, 2);
      expect(loadingStates, isNot(contains(true)));
      model.dispose();
    });

    test('reordering completed tasks preserves completion dates', () async {
      final model = KanbanViewModel(
        FakeKanbanRepository(
          tasks: [
            sampleTask('1', 'First', KanbanStatus.completed),
            sampleTask('2', 'Second', KanbanStatus.completed, order: 1),
          ],
        ),
      );
      await model.initialize();
      final completedAt = model.allTasks.first.completedAt;
      expect(await model.reorderTask('1', KanbanStatus.completed, 1), true);
      expect(
        model.allTasks.where((task) => task.id == '1').single.completedAt,
        completedAt,
      );
      model.dispose();
    });

    test('reorders tasks and archives with undo', () async {
      final model = KanbanViewModel(
        FakeKanbanRepository(
          tasks: [
            sampleTask('1', 'First', KanbanStatus.todo),
            sampleTask('2', 'Second', KanbanStatus.todo, order: 1),
          ],
        ),
      );
      await model.initialize();
      expect(await model.reorderTask('2', KanbanStatus.todo, 0), true);
      expect(model.tasks(KanbanStatus.todo).first.id, '2');
      expect(await model.archiveTask('2'), true);
      expect(model.totalTaskCount, 1);
      expect(await model.undoLastAction(), true);
      expect(model.totalTaskCount, 2);
      model.dispose();
    });

    test('archives and restores the active board', () async {
      final repo = FakeKanbanRepository(
        tasks: [sampleTask('1', 'Plan', KanbanStatus.todo)],
      );
      final model = KanbanViewModel(repo);
      await model.initialize();
      expect(await model.archiveBoard(), true);
      expect(model.isBoardArchived, true);
      expect(model.totalTaskCount, 0);
      expect(repo.boardArchived, true);
      expect(await model.restoreArchivedBoard(), true);
      expect(model.isBoardArchived, false);
      expect(model.totalTaskCount, 1);
      model.dispose();
    });

    test(
      'search, combined filters and sorting apply inside statuses',
      () async {
        final tag = TaskTag(
          id: 't',
          ownerId: 'user-1',
          name: 'Research',
          colorHex: '#000000',
        );
        final model = KanbanViewModel(
          FakeKanbanRepository(
            tasks: [
              sampleTask(
                '1',
                'Alpha',
                KanbanStatus.todo,
                order: 1,
                priority: TaskPriority.low,
                tags: [tag],
              ),
              sampleTask(
                '2',
                'Beta',
                KanbanStatus.todo,
                order: 0,
                priority: TaskPriority.high,
                tags: [tag],
              ),
              sampleTask('3', 'Gamma', KanbanStatus.completed),
            ],
          ),
        );
        await model.initialize();
        model.setSearchQuery('research');
        expect(model.visibleTasks(KanbanStatus.todo).length, 2);
        model.applyFilter(
          KanbanFilter(
            statuses: {KanbanStatus.todo},
            priorities: {TaskPriority.high},
            tagIds: {'t'},
          ),
        );
        expect(model.visibleTasks(KanbanStatus.todo).single.id, '2');
        model.setSearchQuery('');
        model.clearFilters();
        model.setSort(KanbanSort.highestPriority);
        expect(model.visibleTasks(KanbanStatus.todo).first.id, '2');
        model.dispose();
      },
    );

    test('tag duplicate rejection and checklist completion', () async {
      final item = TaskChecklistItem(
        id: 'c',
        taskId: '1',
        title: 'Draft',
        isCompleted: false,
        position: 0,
      );
      final model = KanbanViewModel(
        FakeKanbanRepository(
          tasks: [
            sampleTask('1', 'Plan', KanbanStatus.todo, checklist: [item]),
          ],
        ),
      );
      await model.initialize();
      expect(await model.createTag('Revision', '#000000'), true);
      expect(await model.createTag('revision', '#000000'), false);
      expect(await model.toggleChecklistItem(item), true);
      expect(model.allTasks.single.checklistCompletedCount, 1);
      model.dispose();
    });

    test(
      'tag creation and editing normalize colors and update task chips',
      () async {
        const revision = TaskTag(
          id: 'tag-1',
          ownerId: 'user-1',
          name: 'Revision',
          colorHex: '#5C6BC0',
        );
        final repo = FakeKanbanRepository(
          tasks: [
            sampleTask('1', 'Plan', KanbanStatus.todo, tags: [revision]),
          ],
        )..tags = [revision];
        final model = KanbanViewModel(repo);
        await model.initialize();
        expect(await model.createTag('revision', '#00897B'), false);
        expect(model.errorMessage, 'A tag with this name already exists.');
        expect(await model.createTag('New tag', '5c6bc0'), true);
        expect(repo.tags.last.colorHex, '#5C6BC0');
        expect(await model.updateTag(revision, 'Revision', '#00897b'), true);
        expect(repo.tags.first.colorHex, '#00897B');
        expect(model.availableTags.first.colorHex, '#00897B');
        expect(
          model.tasks(KanbanStatus.todo).single.tags.single.colorHex,
          '#00897B',
        );
        model.dispose();
      },
    );

    test('tag validation uses friendly messages', () async {
      final model = KanbanViewModel(FakeKanbanRepository());
      await model.initialize();
      expect(await model.createTag('   ', '#5C6BC0'), false);
      expect(model.errorMessage, 'Tag name is required.');
      expect(await model.createTag('Bad', '#FFF'), false);
      expect(model.errorMessage, 'Enter a valid 6-digit hex color.');
      model.dispose();
    });

    test('tag repository failures do not expose raw exceptions', () async {
      final repo = FakeKanbanRepository()..failTagCreate = true;
      final model = KanbanViewModel(repo);
      await model.initialize();
      expect(await model.createTag('Study', '#5C6BC0'), false);
      expect(model.errorMessage, 'Unable to save the tag. Please try again.');
      repo.failTagCreate = false;
      expect(await model.createTag('Study', '#5C6BC0'), true);
      repo.failTagDelete = true;
      expect(await model.deleteTag(repo.tags.single.id), false);
      expect(model.errorMessage, 'Unable to delete the tag. Please try again.');
      model.dispose();
    });

    test('repository move failure rolls back optimistic state', () async {
      final repo = FakeKanbanRepository(
        tasks: [sampleTask('1', 'Plan', KanbanStatus.todo)],
      );
      final model = KanbanViewModel(repo);
      await model.initialize();
      repo.failMove = true;
      expect(await model.completeTask('1'), false);
      expect(model.allTasks.single.status, KanbanStatus.todo);
      expect(model.errorMessage, 'Unable to move the task. Please try again.');
      model.dispose();
    });

    test('failed tag attachment removes a partly created task', () async {
      final repo = FakeKanbanRepository()..failTagAttach = true;
      final model = KanbanViewModel(repo);
      await model.initialize();
      expect(await model.createTask(title: 'Plan', tagIds: ['tag']), false);
      expect(model.allTasks, isEmpty);
      expect(repo.stored, isEmpty);
      model.dispose();
    });
  });
}
