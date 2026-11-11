import 'dart:typed_data';

import '../models/kanban_status.dart';
import '../models/kanban_task.dart';
import '../models/task_activity.dart';
import '../models/task_attachment.dart';
import '../models/task_checklist_item.dart';
import '../models/task_tag.dart';
import '../../ai_task_generation/models/generated_task_draft.dart';
import '../../ai_task_generation/models/task_generation_request.dart';

abstract class KanbanRepository {
  String? get currentUserId;
  Future<void> signIn(String email, String password);
  Future<String?> getFirstBoardId({bool archived = false});
  Future<void> setBoardArchived(String boardId, bool archived);
  Future<List<KanbanTask>> getTasks(String boardId);
  Future<KanbanTask?> getTask(String boardId, String taskId);
  Future<bool> hasActiveTask(String boardId, String taskId);
  Future<List<KanbanTask>> getArchivedTasks(String boardId);
  Future<List<ExistingTaskSummary>> getTaskSummaries(String boardId);
  Future<KanbanTask> createTask(KanbanTask task);
  Future<KanbanTask> saveTaskCreation(
    KanbanTask task, {
    required String requestId,
    required List<String> tagIds,
    required List<String> checklist,
  });
  Future<KanbanTask> saveTaskMove(
    KanbanTask task,
    KanbanStatus status, {
    required String requestId,
    int? newIndex,
  });
  Future<KanbanTask> saveTaskArchive(
    KanbanTask task,
    bool archived, {
    required String requestId,
  });
  Future<KanbanTask> saveTaskResume(
    KanbanTask task, {
    required String requestId,
  });
  Future<void> createGeneratedTasks(
    String boardId,
    List<GeneratedTaskDraft> tasks, {
    String? requestId,
  });
  Future<KanbanTask> saveTaskEdit(
    KanbanTask task, {
    required String requestId,
    List<String>? tagIds,
  });
  Future<KanbanTask> resumeTask(KanbanTask task);
  Future<KanbanTask> setTaskTimerPaused(KanbanTask task, bool paused);
  Future<void> archiveTask(String taskId, bool archived);
  Future<void> deleteTask(String taskId);
  Future<KanbanTask> moveTask(
    KanbanTask task,
    KanbanStatus status,
    int order, {
    DateTime? completedAt,
  });
  Future<void> reorderTasks(List<KanbanTask> tasks);
  Future<List<TaskTag>> getUserTags(String userId);
  Future<TaskTag> createTag(String userId, String name, String colorHex);
  Future<TaskTag> updateTag(TaskTag tag);
  Future<void> deleteTag(String tagId);
  Future<void> attachTagToTask(String taskId, String tagId);
  Future<void> removeTagFromTask(String taskId, String tagId);
  Future<TaskChecklistItem> createChecklistItem(
    String taskId,
    String title,
    int position,
  );
  Future<TaskChecklistItem> updateChecklistItem(TaskChecklistItem item);
  Future<void> deleteChecklistItem(String itemId);
  Future<void> reorderChecklistItems(List<TaskChecklistItem> items);
  Future<TaskAttachment> uploadAttachment(
    String taskId,
    String fileName,
    Uint8List bytes,
    String? mimeType,
  );
  Future<void> deleteAttachment(TaskAttachment attachment);
  Future<void> retryAttachmentCleanup();
  Future<String> getAttachmentUrl(TaskAttachment attachment);
  Future<List<TaskActivity>> getTaskActivity(String taskId);
  Future<void> addProgressUpdate(
    String taskId,
    String text, {
    required String requestId,
  });
  Future<void> addActivity(
    String taskId,
    String action, {
    Map<String, dynamic> oldValues = const {},
    Map<String, dynamic> newValues = const {},
  });
}

abstract interface class TaskListReplacementRepository {
  Future<Map<String, dynamic>> replacementContext(String boardId);
  Future<void> replaceGeneratedTasks(
    String boardId,
    List<GeneratedTaskDraft> tasks, {
    required String requestId,
    required String expectedVersion,
  });
}
