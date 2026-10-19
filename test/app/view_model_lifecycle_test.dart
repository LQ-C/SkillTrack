import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:skilltrack/features/kanban/models/kanban_status.dart';
import 'package:skilltrack/features/kanban/models/kanban_task.dart';
import 'package:skilltrack/features/kanban/models/task_tag.dart';
import 'package:skilltrack/features/kanban/viewmodels/archived_tasks_view_model.dart';
import 'package:skilltrack/features/kanban/viewmodels/kanban_view_model.dart';
import 'package:skilltrack/features/notifications/models/notification_preferences.dart';
import 'package:skilltrack/features/notifications/viewmodels/notification_preferences_view_model.dart';
import 'package:skilltrack/features/projects/models/project_with_progress.dart';
import 'package:skilltrack/features/projects/viewmodels/create_project_view_model.dart';
import 'package:skilltrack/features/projects/viewmodels/project_dashboard_view_model.dart';

import '../features/kanban/fake_repository.dart';
import '../features/notifications/fake_notification_repository.dart';
import '../features/projects/fake_project_repository.dart';

class _KanbanRepository extends FakeKanbanRepository {
  _KanbanRepository({super.tasks});
  Completer<List<KanbanTask>>? pendingTasks, pendingArchive;
  Completer<void>? pendingSave;
  int loads = 0, tagLoads = 0;
  @override
  Future<List<KanbanTask>> getTasks(String boardId) {
    loads++;
    return pendingTasks?.future ?? super.getTasks(boardId);
  }

  @override
  Future<List<KanbanTask>> getArchivedTasks(String boardId) {
    loads++;
    return pendingArchive?.future ?? super.getArchivedTasks(boardId);
  }

  @override
  Future<List<TaskTag>> getUserTags(String userId) {
    tagLoads++;
    return super.getUserTags(userId);
  }

  @override
  Future<KanbanTask> updateTask(KanbanTask task) async {
    await pendingSave?.future;
    return super.updateTask(task);
  }

  @override
  Future<void> archiveTask(String taskId, bool archived) async {
    await pendingSave?.future;
    await super.archiveTask(taskId, archived);
  }
}

class _ProjectRepository extends FakeProjectRepository {
  _ProjectRepository({super.items});
  Completer<List<ProjectWithProgress>>? pendingLoad;
  Completer<void>? pendingSave;
  int loads = 0;
  @override
  Future<List<ProjectWithProgress>> getProjectsWithProgress() {
    loads++;
    return pendingLoad?.future ?? super.getProjectsWithProgress();
  }

  @override
  Future<void> archiveProject(String projectId) async {
    await pendingSave?.future;
    await super.archiveProject(projectId);
  }

  @override
  Future<ProjectWithProgress> createProject({
    required String name,
    String? description,
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    await pendingSave?.future;
    return super.createProject(
      name: name,
      description: description,
      startDate: startDate,
      endDate: endDate,
    );
  }
}

class _NotificationRepository extends FakeNotificationRepository {
  Completer<NotificationPreferences>? pendingLoad, pendingSave;
  @override
  Future<NotificationPreferences> getPreferences() =>
      pendingLoad?.future ?? super.getPreferences();
  @override
  Future<NotificationPreferences> updatePreferences(
    NotificationPreferences next,
  ) => pendingSave?.future ?? super.updatePreferences(next);
}

void _complete<T>(Completer<T> pending, T result, bool fail) {
  if (fail) {
    pending.completeError(StateError('internal database detail'));
  } else {
    pending.complete(result);
  }
}

void main() {
  for (final fail in [false, true]) {
    final outcome = fail ? 'fails' : 'succeeds';
    test(
      'Kanban load $outcome after disposal without notifying or starting further reads',
      () async {
        final repo = _KanbanRepository()
          ..pendingTasks = Completer<List<KanbanTask>>();
        final model = KanbanViewModel(repo);
        var notifications = 0;
        model.addListener(() => notifications++);
        final loading = model.initialize('board-1');
        model.dispose();
        final before = notifications;
        _complete(repo.pendingTasks!, [
          sampleTask('1', 'Late', KanbanStatus.todo),
        ], fail);
        await loading;
        expect(notifications, before);
        expect(model.allTasks, isEmpty);
        expect(
          repo.tagLoads,
          1,
        ); // Started with the task read, before disposal.
        await model.refresh();
        expect(repo.loads, 1);
      },
    );

    test(
      'Archived task load $outcome after disposal without applying results',
      () async {
        final repo = _KanbanRepository()
          ..pendingArchive = Completer<List<KanbanTask>>();
        final model = ArchivedTasksViewModel(repo);
        final loading = model.loadArchivedTasks('board-1');
        model.dispose();
        _complete(repo.pendingArchive!, [
          sampleTask('1', 'Late', KanbanStatus.todo).copyWith(isArchived: true),
        ], fail);
        await loading;
        expect(model.archivedTasks, isEmpty);
      },
    );

    test(
      'Project load $outcome after disposal without applying results',
      () async {
        final repo = _ProjectRepository()
          ..pendingLoad = Completer<List<ProjectWithProgress>>();
        final model = ProjectDashboardViewModel(repo);
        final loading = model.load();
        model.dispose();
        _complete(repo.pendingLoad!, [sampleProject('1', 'Late')], fail);
        await loading;
        expect(model.projects, isEmpty);
        await model.load();
        expect(repo.loads, 1);
      },
    );

    test(
      'Preferences load $outcome after disposal without applying results',
      () async {
        final repo = _NotificationRepository()
          ..pendingLoad = Completer<NotificationPreferences>();
        final model = NotificationPreferencesViewModel(repo);
        final loading = model.initialize();
        model.dispose();
        _complete(
          repo.pendingLoad!,
          NotificationPreferences.defaults(
            'user',
          ).copyWith(stalledTaskEnabled: false),
          fail,
        );
        await loading;
        expect(model.hasLoaded, isFalse);
        expect(model.preferences.stalledTaskEnabled, isTrue);
      },
    );

    test(
      'Project form save $outcome after disposal without publishing a result',
      () async {
        final repo = _ProjectRepository()..pendingSave = Completer<void>();
        final model = CreateProjectViewModel(repo);
        final saving = model.submit(name: 'Created', description: '');
        model.dispose();
        _complete<void>(repo.pendingSave!, null, fail);
        expect(await saving, isNull);
        expect(repo.stored.length, fail ? 0 : 1);
      },
    );

    test('Kanban edit $outcome after disposal without refreshing', () async {
      final task = sampleTask('1', 'Original', KanbanStatus.todo);
      final repo = _KanbanRepository(tasks: [task]);
      final model = KanbanViewModel(repo);
      await model.initialize('board-1');
      repo.pendingSave = Completer<void>();
      final saving = model.updateTask(
        task,
        title: 'Edited',
        description: '',
        status: task.status,
        priority: task.priority,
      );
      model.dispose();
      _complete<void>(repo.pendingSave!, null, fail);
      expect(await saving, isFalse);
      expect(repo.loads, 1);
      expect(model.allTasks.single.title, 'Original');
      expect(repo.stored.single.title, fail ? 'Original' : 'Edited');
    });

    test(
      'Archived task restore $outcome after disposal without notifying',
      () async {
        final task = sampleTask(
          '1',
          'Archived',
          KanbanStatus.todo,
        ).copyWith(isArchived: true);
        final repo = _KanbanRepository(tasks: [task]);
        final model = ArchivedTasksViewModel(repo);
        await model.loadArchivedTasks('board-1');
        repo.pendingSave = Completer<void>();
        final restoring = model.restoreTask('1');
        model.dispose();
        _complete<void>(repo.pendingSave!, null, fail);
        expect(await restoring, isFalse);
        expect(repo.stored.single.isArchived, fail);
        expect(repo.loads, 1);
      },
    );

    test(
      'Project archive $outcome after disposal without refreshing',
      () async {
        final repo = _ProjectRepository(items: [sampleProject('1', 'Study')]);
        final model = ProjectDashboardViewModel(repo);
        await model.load();
        repo.pendingSave = Completer<void>();
        final saving = model.archive('1');
        model.dispose();
        _complete<void>(repo.pendingSave!, null, fail);
        expect(await saving, isFalse);
        expect(repo.loads, 1);
        expect(repo.stored.single.project.status, fail ? 'active' : 'archived');
      },
    );

    test(
      'Preferences save $outcome after disposal without notifying',
      () async {
        final repo = _NotificationRepository();
        final model = NotificationPreferencesViewModel(repo);
        await model.initialize();
        repo.pendingSave = Completer<NotificationPreferences>();
        final saving = model.setStalledTaskEnabled(false);
        model.dispose();
        _complete(repo.pendingSave!, model.preferences, fail);
        await saving;
      },
    );
  }
}
