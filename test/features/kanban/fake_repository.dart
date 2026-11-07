import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:skilltrack/features/kanban/models/kanban_status.dart';
import 'package:skilltrack/features/kanban/models/kanban_task.dart';
import 'package:skilltrack/features/kanban/models/task_activity.dart';
import 'package:skilltrack/features/kanban/models/task_attachment.dart';
import 'package:skilltrack/features/kanban/models/task_checklist_item.dart';
import 'package:skilltrack/features/kanban/models/task_priority.dart';
import 'package:skilltrack/features/kanban/models/task_tag.dart';
import 'package:skilltrack/features/kanban/repositories/kanban_repository.dart';
import 'package:skilltrack/features/ai_task_generation/models/generated_task_draft.dart';
import 'package:skilltrack/features/ai_task_generation/models/task_generation_request.dart';

class FakeKanbanRepository extends Fake implements KanbanRepository {
  FakeKanbanRepository({
    List<KanbanTask>? tasks,
    this.failLoad = false,
    this.noBoard = false,
    this.tasksByBoard,
  }) : stored = List.of(tasks ?? []);
  List<KanbanTask> stored;
  final Map<String, List<KanbanTask>>? tasksByBoard;
  List<TaskTag> tags = [];
  bool failLoad;
  bool noBoard;
  bool failMove = false;
  bool failTimer = false;
  int timerCalls = 0;
  bool failReorderOnce = false;
  bool failArchive = false;
  final Set<String> failArchiveIds = {};
  bool failDelete = false;
  int moveCalls = 0;
  int reorderCalls = 0;
  int generatedInsertCalls = 0;
  int summaryCalls = 0;
  bool failGeneratedInsert = false;
  bool loseGeneratedResponseOnce = false;
  final generatedRequests = <String, String>{};
  final generatedRequestIds = <String?>[];
  final activityEvents =
      <
        ({
          String taskId,
          String action,
          Map<String, dynamic> oldValues,
          Map<String, dynamic> newValues,
        })
      >[];
  bool failTagAttach = false;
  bool failTagCreate = false;
  bool failTagUpdate = false;
  bool failTagDelete = false;
  bool boardArchived = false;
  int _nextId = 10;
  @override
  String? get currentUserId => 'user-1';
  @override
  Future<void> signIn(String email, String password) async {}
  @override
  Future<String?> getFirstBoardId({bool archived = false}) async =>
      !noBoard && boardArchived == archived ? 'board-1' : null;
  @override
  Future<void> setBoardArchived(String boardId, bool archived) async {
    boardArchived = archived;
  }

  @override
  Future<List<KanbanTask>> getTasks(String boardId) async {
    boardReads++;
    if (failLoad) throw StateError('offline');
    return (tasksByBoard?[boardId] ??
            stored.where((task) => task.boardId == boardId))
        .where((task) => !task.isArchived)
        .toList();
  }

  @override
  Future<List<KanbanTask>> getArchivedTasks(String boardId) async {
    if (failLoad) throw StateError('offline');
    return (tasksByBoard?[boardId] ??
            stored.where((task) => task.boardId == boardId))
        .where((task) => task.isArchived)
        .toList();
  }

  @override
  Future<List<ExistingTaskSummary>> getTaskSummaries(String boardId) async {
    summaryCalls++;
    if (failLoad) throw StateError('offline');
    return [
      for (final task
          in tasksByBoard?[boardId] ??
              stored.where((task) => task.boardId == boardId))
        ExistingTaskSummary(
          title: task.title,
          description: task.description,
          status: task.isArchived ? 'archived' : task.status.value,
          deadline: task.deadline,
          sortOrder: task.sortOrder,
          milestoneId: task.milestoneId,
        ),
    ];
  }

  @override
  Future<List<TaskTag>> getUserTags(String userId) async => List.of(tags);
  @override
  Future<KanbanTask> createTask(KanbanTask task) async {
    final created = task.copyWith(
      id: '${_nextId++}',
      trackingStartedAt: task.status == KanbanStatus.inProgress
          ? DateTime.now().toUtc()
          : null,
      elapsedSeconds: 0,
    );
    stored.add(created);
    return created;
  }

  final taskRequests = <({String operation, String id, Object payload})>[];
  final _actionReceipts = <(String, String), KanbanTask>{};
  String? loseTaskActionResponseOnce;

  Future<KanbanTask> _atomicAction(
    String operation,
    String id,
    Object payload,
    Future<KanbanTask> Function() action,
  ) async {
    taskRequests.add((operation: operation, id: id, payload: payload));
    final key = (operation, id);
    if (_actionReceipts[key] case final result?) return result;
    final previous = List.of(stored);
    final boardSnapshots = tasksByBoard?.map(
      (key, tasks) => MapEntry(key, List.of(tasks)),
    );
    final logs = activityEvents.length;
    final KanbanTask result;
    try {
      result = await action();
    } catch (_) {
      stored = previous;
      if (boardSnapshots != null) tasksByBoard!.addAll(boardSnapshots);
      activityEvents.removeRange(logs, activityEvents.length);
      rethrow;
    }
    _actionReceipts[key] = result;
    if (loseTaskActionResponseOnce == operation) {
      loseTaskActionResponseOnce = null;
      throw StateError('response lost');
    }
    return result;
  }

  @override
  Future<KanbanTask> saveTaskCreation(
    KanbanTask task, {
    required String requestId,
    required List<String> tagIds,
    required List<String> checklist,
  }) => _atomicAction(
    'create',
    requestId,
    (task, tagIds.join(','), checklist.join(',')),
    () async {
      final created = await createTask(task);
      for (final tag in tagIds) {
        await attachTagToTask(created.id, tag);
      }
      for (final (index, title) in checklist.indexed) {
        if (title.isNotEmpty) {
          await createChecklistItem(created.id, title, index);
        }
      }
      await addActivity(
        created.id,
        'created',
        newValues: {'title': created.title},
      );
      return stored.singleWhere((item) => item.id == created.id);
    },
  );

  @override
  Future<KanbanTask> saveTaskMove(
    KanbanTask task,
    KanbanStatus status, {
    required String requestId,
    int? newIndex,
  }) => _atomicAction('move', requestId, (task, status, newIndex), () async {
    List<KanbanTask> column(KanbanStatus status) =>
        stored
            .where(
              (item) =>
                  item.boardId == task.boardId &&
                  item.status == status &&
                  !item.isArchived,
            )
            .toList()
          ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    final oldIndex = column(
      task.status,
    ).indexWhere((item) => item.id == task.id);
    final target = column(status)..removeWhere((item) => item.id == task.id);
    final index = (newIndex ?? target.length).clamp(0, target.length);
    final before = index > 0 ? target[index - 1].sortOrder : 0;
    final after = index < target.length
        ? target[index].sortOrder
        : before + 2000;
    final normalize = after - before <= 1;
    final order = normalize ? (index + 1) * 1000 : (before + after) ~/ 2;
    final moved = task.status == status
        ? task.copyWith(sortOrder: order)
        : await moveTask(task, status, order);
    if (normalize) {
      target.insert(index, moved);
      await reorderTasks([
        for (final (position, item) in target.indexed)
          item.copyWith(sortOrder: (position + 1) * 1000),
      ]);
    } else if (task.status == status) {
      await reorderTasks([moved]);
    }
    if (task.status != status) {
      await addActivity(
        task.id,
        status == KanbanStatus.completed
            ? 'completed'
            : task.status == KanbanStatus.completed
            ? 'reopened'
            : 'moved',
        oldValues: {'status': task.status.value, 'position': oldIndex},
        newValues: {'status': status.value, 'position': index},
      );
    }
    return stored.singleWhere((item) => item.id == task.id);
  });

  @override
  Future<KanbanTask> saveTaskArchive(
    KanbanTask task,
    bool archived, {
    required String requestId,
  }) => _atomicAction(
    archived ? 'archive' : 'restore',
    requestId,
    task,
    () async {
      await archiveTask(task.id, archived);
      await addActivity(task.id, archived ? 'archived' : 'restored');
      return (tasksByBoard?[task.boardId] ?? stored).singleWhere(
        (item) => item.id == task.id,
      );
    },
  );

  @override
  Future<KanbanTask> saveTaskResume(
    KanbanTask task, {
    required String requestId,
  }) => _atomicAction('resume', requestId, task, () => resumeTask(task));

  @override
  Future<void> createGeneratedTasks(
    String boardId,
    List<GeneratedTaskDraft> tasks, {
    String? requestId,
  }) async {
    generatedInsertCalls++;
    generatedRequestIds.add(requestId);
    final payload = tasks
        .map((task) => task.toRevisionJson().toString())
        .join();
    if (requestId != null && generatedRequests.containsKey(requestId)) {
      if (generatedRequests[requestId] != payload) {
        throw StateError("request reused");
      }
      return;
    }
    if (failGeneratedInsert) throw StateError('batch failed');
    final startingSortOrder = stored
        .where(
          (task) =>
              task.boardId == boardId &&
              task.status == KanbanStatus.todo &&
              !task.isArchived,
        )
        .fold<int>(
          0,
          (highest, task) =>
              task.sortOrder > highest ? task.sortOrder : highest,
        );
    final now = DateTime.now();
    for (var taskIndex = 0; taskIndex < tasks.length; taskIndex++) {
      final draft = tasks[taskIndex];
      final taskId = '${_nextId++}';
      stored.add(
        KanbanTask(
          id: taskId,
          boardId: boardId,
          title: draft.title,
          milestoneId:
              draft.milestone?.existingMilestoneId ?? draft.milestone?.localId,
          description: draft.description,
          status: KanbanStatus.todo,
          priority: TaskPriority.fromValue(draft.priority),
          deadline: draft.deadline,
          sortOrder: startingSortOrder + (taskIndex + 1) * 1000,
          createdAt: now,
          updatedAt: now,
          checklistItems: [
            for (var index = 0; index < draft.checklist.length; index++)
              TaskChecklistItem(
                id: '$taskId-$index',
                taskId: taskId,
                title: draft.checklist[index],
                isCompleted: false,
                position: index,
              ),
          ],
        ),
      );
    }
    if (requestId != null) generatedRequests[requestId] = payload;
    if (loseGeneratedResponseOnce) {
      loseGeneratedResponseOnce = false;
      throw StateError('Response lost after commit');
    }
  }

  final editRequestIds = <String>[];
  final _savedEdits = <String>{};
  bool loseEditResponseOnce = false;
  int boardReads = 0, taskReads = 0, existenceReads = 0;

  @override
  Future<KanbanTask?> getTask(String boardId, String taskId) async {
    taskReads++;
    return _activeTask(boardId, taskId);
  }

  @override
  Future<bool> hasActiveTask(String boardId, String taskId) async {
    existenceReads++;
    return _activeTask(boardId, taskId) != null;
  }

  KanbanTask? _activeTask(String boardId, String taskId) {
    if (failLoad) throw StateError('offline');
    return (tasksByBoard?[boardId] ?? stored)
        .where(
          (task) =>
              task.boardId == boardId && task.id == taskId && !task.isArchived,
        )
        .firstOrNull;
  }

  @override
  Future<void> retryAttachmentCleanup() async {}

  @override
  Future<KanbanTask> saveTaskEdit(
    KanbanTask task, {
    required String requestId,
    List<String>? tagIds,
  }) async {
    editRequestIds.add(requestId);
    final original = stored.firstWhere((item) => item.id == task.id);
    if (_savedEdits.contains(requestId)) return original;
    final snapshot = List.of(stored);
    final activityCount = activityEvents.length;
    try {
      var current = original;
      if (original.status != task.status) {
        final order = stored
            .where(
              (item) =>
                  item.boardId == task.boardId &&
                  item.status == task.status &&
                  !item.isArchived,
            )
            .fold(
              0,
              (max, item) => item.sortOrder > max ? item.sortOrder : max,
            );
        current = await moveTask(original, task.status, order + 1000);
      }
      await updateTask(
        task.copyWith(
          sortOrder: current.sortOrder,
          completedAt: current.completedAt,
          clearCompletedAt: current.completedAt == null,
          trackingStartedAt: current.trackingStartedAt,
          clearTrackingStartedAt: current.trackingStartedAt == null,
          elapsedSeconds: current.elapsedSeconds,
        ),
      );
      await addActivity(task.id, 'updated', newValues: {'title': task.title});
      if (original.status != task.status) {
        await addActivity(
          task.id,
          task.status == KanbanStatus.completed
              ? 'completed'
              : original.status == KanbanStatus.completed
              ? 'reopened'
              : 'moved',
          oldValues: {'status': original.status.value},
          newValues: {'status': task.status.value},
        );
      }
      if (tagIds != null) {
        final oldIds = original.tags.map((tag) => tag.id).toSet();
        final newIds = tagIds.toSet();
        for (final id in oldIds.difference(newIds)) {
          await removeTagFromTask(task.id, id);
        }
        for (final id in newIds.difference(oldIds)) {
          await attachTagToTask(task.id, id);
        }
      }
    } catch (_) {
      stored = snapshot;
      activityEvents.removeRange(activityCount, activityEvents.length);
      rethrow;
    }
    _savedEdits.add(requestId);
    if (loseEditResponseOnce) {
      loseEditResponseOnce = false;
      throw StateError('response lost');
    }
    return stored.firstWhere((item) => item.id == task.id);
  }

  Future<KanbanTask> updateTask(KanbanTask task) async {
    stored = stored.map((item) => item.id == task.id ? task : item).toList();
    return task;
  }

  @override
  Future<KanbanTask> resumeTask(KanbanTask task) async {
    final resumed = task.copyWith(
      isStalled: false,
      stagnationScore: 0,
      clearStalledAt: true,
      lastActivityAt: DateTime.now().toUtc(),
    );
    stored = stored.map((item) => item.id == task.id ? resumed : item).toList();
    await addActivity(task.id, 'resumed');
    return resumed;
  }

  @override
  Future<KanbanTask> moveTask(
    KanbanTask task,
    KanbanStatus status,
    int order, {
    DateTime? completedAt,
  }) async {
    moveCalls++;
    if (failMove) throw StateError('move failed');
    final current = stored.singleWhere((item) => item.id == task.id);
    final now = DateTime.now().toUtc();
    final changed = current.status != status;
    final updated = current.copyWith(
      status: status,
      sortOrder: order,
      elapsedSeconds: changed
          ? current.trackedDurationAt(now).inSeconds
          : current.elapsedSeconds,
      trackingStartedAt: changed && status == KanbanStatus.inProgress
          ? now
          : current.trackingStartedAt,
      clearTrackingStartedAt: changed && status != KanbanStatus.inProgress,
      completedAt: status == KanbanStatus.completed
          ? (completedAt ?? now)
          : null,
      clearCompletedAt: status != KanbanStatus.completed,
      updatedAt: now,
    );
    stored = [for (final item in stored) item.id == task.id ? updated : item];
    return updated;
  }

  @override
  Future<KanbanTask> setTaskTimerPaused(KanbanTask task, bool paused) async {
    timerCalls++;
    if (failTimer) throw StateError('timer failed');
    final current = stored.singleWhere((item) => item.id == task.id);
    final now = DateTime.now().toUtc();
    final updated = current.copyWith(
      elapsedSeconds: paused
          ? current.trackedDurationAt(now).inSeconds
          : current.elapsedSeconds,
      trackingStartedAt: paused ? null : current.trackingStartedAt ?? now,
      clearTrackingStartedAt: paused,
      updatedAt: now,
    );
    stored = [for (final item in stored) item.id == task.id ? updated : item];
    return updated;
  }

  @override
  Future<void> reorderTasks(List<KanbanTask> tasks) async {
    reorderCalls++;
    final byId = {for (final task in tasks) task.id: task};
    stored = stored
        .map((item) => item.copyWith(sortOrder: byId[item.id]?.sortOrder))
        .toList();
    if (failReorderOnce) {
      failReorderOnce = false;
      throw StateError('reorder failed after partial persistence');
    }
  }

  @override
  Future<void> archiveTask(String taskId, bool archived) async {
    if (archived) {
      final task = stored.singleWhere((task) => task.id == taskId);
      if (task.isTracking) await setTaskTimerPaused(task, true);
    }
    if (failArchive || failArchiveIds.contains(taskId)) {
      throw StateError('archive failed');
    }
    stored = stored
        .map(
          (item) =>
              item.id == taskId ? item.copyWith(isArchived: archived) : item,
        )
        .toList();
    for (final boardId in tasksByBoard?.keys ?? <String>[]) {
      tasksByBoard![boardId] = tasksByBoard![boardId]!
          .map(
            (task) =>
                task.id == taskId ? task.copyWith(isArchived: archived) : task,
          )
          .toList();
    }
  }

  @override
  Future<void> deleteTask(String taskId) async {
    if (failDelete) throw StateError('delete failed');
    stored.removeWhere((item) => item.id == taskId);
    for (final boardId in tasksByBoard?.keys ?? <String>[]) {
      tasksByBoard![boardId]!.removeWhere((item) => item.id == taskId);
    }
  }

  @override
  Future<TaskTag> createTag(String userId, String name, String colorHex) async {
    if (failTagCreate) throw StateError('tag create failed');
    final tag = TaskTag(
      id: '${_nextId++}',
      ownerId: userId,
      name: name,
      colorHex: colorHex,
    );
    tags.add(tag);
    return tag;
  }

  @override
  Future<TaskTag> updateTag(TaskTag tag) async {
    if (failTagUpdate) throw StateError('tag update failed');
    tags = tags.map((item) => item.id == tag.id ? tag : item).toList();
    stored = stored
        .map(
          (task) => task.copyWith(
            tags: task.tags.map((old) => old.id == tag.id ? tag : old).toList(),
          ),
        )
        .toList();
    return tag;
  }

  @override
  Future<void> deleteTag(String tagId) async {
    if (failTagDelete) throw StateError('tag delete failed');
    tags.removeWhere((item) => item.id == tagId);
    stored = stored
        .map(
          (task) => task.copyWith(
            tags: task.tags.where((tag) => tag.id != tagId).toList(),
          ),
        )
        .toList();
  }

  @override
  Future<void> attachTagToTask(String taskId, String tagId) async {
    if (failTagAttach) throw StateError('tag link failed');
    final tag = tags.firstWhere((item) => item.id == tagId);
    stored = stored
        .map(
          (task) => task.id == taskId
              ? task.copyWith(tags: [...task.tags, tag])
              : task,
        )
        .toList();
  }

  @override
  Future<void> removeTagFromTask(String taskId, String tagId) async {
    stored = stored
        .map(
          (task) => task.id == taskId
              ? task.copyWith(
                  tags: task.tags.where((tag) => tag.id != tagId).toList(),
                )
              : task,
        )
        .toList();
  }

  @override
  Future<TaskChecklistItem> createChecklistItem(
    String taskId,
    String title,
    int position,
  ) async {
    final item = TaskChecklistItem(
      id: '${_nextId++}',
      taskId: taskId,
      title: title,
      isCompleted: false,
      position: position,
    );
    stored = stored
        .map(
          (task) => task.id == taskId
              ? task.copyWith(checklistItems: [...task.checklistItems, item])
              : task,
        )
        .toList();
    return item;
  }

  @override
  Future<TaskChecklistItem> updateChecklistItem(TaskChecklistItem item) async {
    stored = stored
        .map(
          (task) => task.id == item.taskId
              ? task.copyWith(
                  checklistItems: task.checklistItems
                      .map((old) => old.id == item.id ? item : old)
                      .toList(),
                )
              : task,
        )
        .toList();
    return item;
  }

  @override
  Future<void> deleteChecklistItem(String itemId) async {
    stored = stored
        .map(
          (task) => task.copyWith(
            checklistItems: task.checklistItems
                .where((item) => item.id != itemId)
                .toList(),
          ),
        )
        .toList();
  }

  @override
  Future<void> reorderChecklistItems(List<TaskChecklistItem> items) async {
    final byId = {for (final item in items) item.id: item};
    stored = stored
        .map(
          (task) => task.copyWith(
            checklistItems:
                task.checklistItems
                    .map((item) => byId[item.id] ?? item)
                    .toList()
                  ..sort((a, b) => a.position.compareTo(b.position)),
          ),
        )
        .toList();
  }

  @override
  Future<TaskAttachment> uploadAttachment(
    String taskId,
    String fileName,
    Uint8List bytes,
    String? mimeType,
  ) async => TaskAttachment(
    id: '${_nextId++}',
    taskId: taskId,
    fileName: fileName,
    storagePath: 'test',
    fileSizeBytes: bytes.length,
  );
  @override
  Future<void> deleteAttachment(TaskAttachment attachment) async {}
  @override
  Future<String> getAttachmentUrl(TaskAttachment attachment) async =>
      'https://example.com';
  @override
  Future<List<TaskActivity>> getTaskActivity(String taskId) async => [];
  int progressCalls = 0;
  bool failProgress = false, loseProgressResponseOnce = false;
  final progressRequestIds = <String>[];
  final _progressReceipts = <String>{};
  @override
  Future<void> addProgressUpdate(
    String taskId,
    String text, {
    required String requestId,
  }) async {
    progressCalls++;
    progressRequestIds.add(requestId);
    if (failProgress) throw StateError('Unable to save');
    if (!_progressReceipts.add(requestId)) return;
    await addActivity(
      taskId,
      'updated',
      newValues: {'change': 'progress_update', 'progress_text': text},
    );
    stored = stored
        .map(
          (task) => task.id == taskId
              ? task.copyWith(
                  isStalled: false,
                  stagnationScore: 0,
                  clearStalledAt: true,
                  lastActivityAt: DateTime.now().toUtc(),
                )
              : task,
        )
        .toList();
    if (loseProgressResponseOnce) {
      loseProgressResponseOnce = false;
      throw StateError('Response lost');
    }
  }

  @override
  Future<void> addActivity(
    String taskId,
    String action, {
    Map<String, dynamic> oldValues = const {},
    Map<String, dynamic> newValues = const {},
  }) async {
    activityEvents.add((
      taskId: taskId,
      action: action,
      oldValues: oldValues,
      newValues: newValues,
    ));
  }
}

KanbanTask sampleTask(
  String id,
  String title,
  KanbanStatus status, {
  int order = 0,
  TaskPriority priority = TaskPriority.medium,
  DateTime? deadline,
  List<TaskTag> tags = const [],
  List<TaskChecklistItem> checklist = const [],
}) {
  final now = DateTime(2026, 10, 5);
  return KanbanTask(
    id: id,
    boardId: 'board-1',
    title: title,
    description: 'Description for $title',
    status: status,
    priority: priority,
    deadline: deadline ?? now.add(const Duration(days: 10)),
    sortOrder: order,
    completedAt: status == KanbanStatus.completed ? now : null,
    createdAt: now,
    updatedAt: now,
    tags: tags,
    checklistItems: checklist,
  );
}
