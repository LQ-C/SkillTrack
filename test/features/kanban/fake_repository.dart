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
  bool failReorderOnce = false;
  bool failArchive = false;
  final Set<String> failArchiveIds = {};
  bool failDelete = false;
  int moveCalls = 0;
  int reorderCalls = 0;
  int generatedInsertCalls = 0;
  bool failGeneratedInsert = false;
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
  Future<List<TaskTag>> getUserTags(String userId) async => List.of(tags);
  @override
  Future<KanbanTask> createTask(KanbanTask task) async {
    final created = task.copyWith(id: '${_nextId++}');
    stored.add(created);
    return created;
  }

  @override
  Future<void> createGeneratedTasks(
    String boardId,
    List<GeneratedTaskDraft> tasks,
  ) async {
    generatedInsertCalls++;
    if (failGeneratedInsert) throw StateError('batch failed');
    final now = DateTime.now();
    for (final draft in tasks) {
      final taskId = '${_nextId++}';
      stored.add(
        KanbanTask(
          id: taskId,
          boardId: boardId,
          title: draft.title,
          description: draft.description,
          status: KanbanStatus.todo,
          priority: TaskPriority.fromValue(draft.priority),
          deadline: draft.deadline,
          sortOrder: (draft.position + 1) * 1000,
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
  }

  @override
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
  Future<void> moveTask(
    KanbanTask task,
    KanbanStatus status,
    int order, {
    DateTime? completedAt,
  }) async {
    moveCalls++;
    if (failMove) throw StateError('move failed');
    stored = stored
        .map(
          (item) => item.id == task.id
              ? item.copyWith(
                  status: status,
                  sortOrder: order,
                  completedAt: status == KanbanStatus.completed
                      ? (completedAt ?? DateTime(2026, 10, 5))
                      : null,
                  clearCompletedAt: status != KanbanStatus.completed,
                )
              : item,
        )
        .toList();
  }

  @override
  Future<void> reorderTasks(List<KanbanTask> tasks) async {
    reorderCalls++;
    final byId = {for (final task in tasks) task.id: task};
    stored = stored.map((item) => byId[item.id] ?? item).toList();
    if (failReorderOnce) {
      failReorderOnce = false;
      throw StateError('reorder failed after partial persistence');
    }
  }

  @override
  Future<void> archiveTask(String taskId, bool archived) async {
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
