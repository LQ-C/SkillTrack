import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;

import '../../../core/errors/app_exception.dart';
import '../../../core/utils/operation_id.dart';
import '../models/kanban_status.dart';
import '../models/kanban_task.dart';
import '../models/task_activity.dart';
import '../models/task_attachment.dart';
import '../models/task_checklist_item.dart';
import '../models/task_tag.dart';
import 'kanban_repository.dart';
import '../../ai_task_generation/models/generated_task_draft.dart';
import '../../ai_task_generation/models/task_generation_request.dart';

class SupabaseKanbanRepository implements KanbanRepository {
  SupabaseKanbanRepository(this._client);
  final SupabaseClient _client;
  static const _bucket = 'task-attachments';

  @override
  String? get currentUserId => _client.auth.currentUser?.id;

  @override
  Future<void> signIn(String email, String password) => _guard(() async {
    await _client.auth.signInWithPassword(email: email, password: password);
  });

  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on AppException {
      rethrow;
    } on AuthException {
      throw const AppException(AppErrorMessages.signInFailed);
    } on PostgrestException catch (error) {
      final missingDeadlineMetadata =
          (error.code == '42703' || error.code == 'PGRST204') &&
          error.message.contains('deadline_has_time');
      if (kDebugMode) {
        debugPrint(
          missingDeadlineMetadata
              ? 'Kanban task setup: deadline_has_time is missing from the API schema. '
                    'Apply task_deadline_timezone.sql and refresh the schema cache.'
              : 'Kanban database request failed (code: ${error.code ?? "unknown"}).',
        );
      }
      if (missingDeadlineMetadata) {
        throw const AppException(AppErrorMessages.taskSetupIncomplete);
      }
      throw AppException(
        error.code == '40001'
            ? AppErrorMessages.taskChanged
            : AppErrorMessages.requestFailed,
      );
    } on StorageException {
      throw const AppException(AppErrorMessages.storageFailed);
    } catch (_) {
      throw const AppException(AppErrorMessages.requestFailed);
    }
  }

  @override
  Future<String?> getFirstBoardId({bool archived = false}) => _guard(() async {
    final userId = currentUserId;
    if (userId == null) {
      throw const AppException('Sign in to view your project board.');
    }
    final projects = await _client
        .from('projects')
        .select('id')
        .eq('owner_id', userId);
    if (projects.isEmpty) return null;
    final boards = await _client
        .from('kanban_boards')
        .select('id')
        .inFilter(
          'project_id',
          projects.map((project) => project['id']).toList(),
        )
        .eq('is_archived', archived)
        .limit(1);
    return boards.isEmpty ? null : boards.first['id'].toString();
  });

  @override
  Future<void> setBoardArchived(String boardId, bool archived) =>
      _guard(() async {
        await _client
            .from('kanban_boards')
            .update({'is_archived': archived})
            .eq('id', boardId)
            .select('id')
            .single();
      });

  @override
  Future<List<KanbanTask>> getTasks(String boardId) =>
      _getTasks(boardId, archived: false);

  @override
  Future<List<KanbanTask>> getArchivedTasks(String boardId) =>
      _getTasks(boardId, archived: true);

  @override
  Future<List<ExistingTaskSummary>> getTaskSummaries(
    String boardId,
  ) => _guard(() async {
    final rows = await _client
        .from('kanban_tasks')
        .select(
          'title,description,status,deadline,sort_order,is_archived,milestone_id',
        )
        .eq('board_id', boardId);
    return [
      for (final row in rows)
        ExistingTaskSummary(
          title: row['title']?.toString() ?? '',
          description: row['description']?.toString() ?? '',
          status: row['is_archived'] == true
              ? 'archived'
              : row['status']?.toString() ?? 'todo',
          deadline: DateTime.tryParse(row['deadline']?.toString() ?? ''),
          sortOrder: (row['sort_order'] as num?)?.toInt() ?? 0,
          milestoneId: row['milestone_id'] as String?,
        ),
    ];
  });

  Future<List<KanbanTask>> _getTasks(
    String boardId, {
    required bool archived,
  }) => _guard(() async {
    final query = _client
        .from('kanban_tasks')
        .select()
        .eq('board_id', boardId)
        .eq('is_archived', archived);
    final rows = archived
        ? await query.order('updated_at', ascending: false)
        : await query.order('sort_order');
    if (rows.isEmpty) return [];
    final ids = rows.map((row) => row['id'].toString()).toList();
    final results = await Future.wait([
      _client
          .from('task_tag_links')
          .select('task_id,tag_id')
          .inFilter('task_id', ids),
      _client
          .from('task_checklist_items')
          .select()
          .inFilter('task_id', ids)
          .order('position'),
      _client.from('task_attachments').select().inFilter('task_id', ids),
    ]);
    final links = results[0];
    final tagIds = links
        .map((row) => row['tag_id'].toString())
        .toSet()
        .toList();
    final tagRows = tagIds.isEmpty
        ? <Map<String, dynamic>>[]
        : await _client.from('task_tags').select().inFilter('id', tagIds);
    final tagsById = {
      for (final row in tagRows) row['id'].toString(): TaskTag.fromMap(row),
    };
    final tagsByTask = _groupByTask(
      links,
      (link) => tagsById[link['tag_id'].toString()],
    );
    final checklistByTask = _groupByTask(results[1], TaskChecklistItem.fromMap);
    final attachmentsByTask = _groupByTask(results[2], TaskAttachment.fromMap);
    return rows.map((row) {
      final id = row['id'].toString();
      return KanbanTask.fromMap(
        row,
        tags: tagsByTask[id] ?? const [],
        checklistItems: checklistByTask[id] ?? const [],
        attachments: attachmentsByTask[id] ?? const [],
      );
    }).toList();
  });

  Map<String, List<T>> _groupByTask<T extends Object>(
    List<Map<String, dynamic>> rows,
    T? Function(Map<String, dynamic>) parse,
  ) {
    final groups = <String, List<T>>{};
    for (final row in rows) {
      final item = parse(row);
      if (item != null) (groups[row['task_id'].toString()] ??= []).add(item);
    }
    return groups;
  }

  @override
  Future<KanbanTask> createTask(KanbanTask task) => _guard(() async {
    final data = task.toMap()..remove('id');
    if (task.status == KanbanStatus.inProgress) data['status'] = 'todo';
    final row = await _client
        .from('kanban_tasks')
        .insert(data)
        .select()
        .single();
    var created = KanbanTask.fromMap(row);
    try {
      if (task.status == KanbanStatus.inProgress) {
        created = await _updateTracking(
          created,
          'move',
          status: KanbanStatus.inProgress,
          order: task.sortOrder,
        );
      }
      await addActivity(
        created.id,
        'created',
        newValues: {'title': created.title},
      );
    } catch (_) {
      await _client.from('kanban_tasks').delete().eq('id', created.id);
      rethrow;
    }
    return created;
  });

  @override
  Future<void> createGeneratedTasks(
    String boardId,
    List<GeneratedTaskDraft> tasks, {
    String? requestId,
  }) => _guard(() async {
    if (tasks.isEmpty) return;
    await _client.rpc(
      tasks.any((task) => task.milestone != null)
          ? 'save_generated_tasks_with_milestones'
          : 'save_generated_tasks',
      params: {
        'p_board_id': boardId,
        'p_request_id': requestId ?? createOperationId(),
        'p_tasks': tasks.map((task) => task.toRevisionJson()).toList(),
      },
    );
  });

  @override
  Future<KanbanTask> updateTask(KanbanTask task) => _guard(() async {
    final row = await _client
        .from('kanban_tasks')
        .update(
          task.toMap()
            ..remove('id')
            ..remove('board_id')
            ..remove('status')
            ..remove('sort_order')
            ..remove('completed_at'),
        )
        .eq('id', task.id)
        .select()
        .single();
    await addActivity(task.id, 'updated', newValues: {'title': task.title});
    return KanbanTask.fromMap(
      row,
      tags: task.tags,
      checklistItems: task.checklistItems,
      attachments: task.attachments,
    );
  });

  @override
  Future<KanbanTask> resumeTask(KanbanTask task) => _guard(() async {
    final now = DateTime.now().toUtc().toIso8601String();
    final row = await _client
        .from('kanban_tasks')
        .update({
          'is_stalled': false,
          'stagnation_score': 0,
          'stalled_at': null,
          'updated_at': now,
        })
        .eq('id', task.id)
        .eq('board_id', task.boardId)
        .select()
        .single();
    await addActivity(task.id, 'resumed');
    return KanbanTask.fromMap(
      row,
      tags: task.tags,
      checklistItems: task.checklistItems,
      attachments: task.attachments,
    );
  });

  @override
  Future<void> archiveTask(String taskId, bool archived) => _guard(() async {
    if (archived) {
      final row = await _client
          .from('kanban_tasks')
          .select()
          .eq('id', taskId)
          .single();
      final task = KanbanTask.fromMap(row);
      if (task.isTracking) await _updateTracking(task, 'pause');
    }
    await _client
        .from('kanban_tasks')
        .update({
          'is_archived': archived,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        })
        .eq('id', taskId);
    await addActivity(taskId, archived ? 'archived' : 'restored');
  });

  @override
  Future<void> deleteTask(String taskId) => _guard(() async {
    final rows = await _client
        .from('task_attachments')
        .select('storage_path')
        .eq('task_id', taskId);
    if (rows.isNotEmpty) {
      await _client.storage
          .from(_bucket)
          .remove(rows.map((row) => row['storage_path'].toString()).toList());
    }
    await _client.from('kanban_tasks').delete().eq('id', taskId);
  });

  @override
  Future<KanbanTask> moveTask(
    KanbanTask task,
    KanbanStatus status,
    int order, {
    DateTime? completedAt,
  }) =>
      _guard(() => _updateTracking(task, 'move', status: status, order: order));

  @override
  Future<KanbanTask> setTaskTimerPaused(KanbanTask task, bool paused) =>
      _guard(() => _updateTracking(task, paused ? 'pause' : 'resume'));

  Future<KanbanTask> _updateTracking(
    KanbanTask task,
    String action, {
    KanbanStatus? status,
    int? order,
  }) async {
    final data = await _client.rpc(
      'update_kanban_task_tracking',
      params: {
        'p_task_id': task.id,
        'p_action': action,
        'p_expected_updated_at': task.updatedAt.toUtc().toIso8601String(),
        if (status != null) 'p_status': status.value,
        'p_sort_order': ?order,
      },
    );
    final row = data is List ? data.single : data;
    return KanbanTask.fromMap(
      Map<String, dynamic>.from(row as Map),
      tags: task.tags,
      checklistItems: task.checklistItems,
      attachments: task.attachments,
    );
  }

  @override
  Future<void> reorderTasks(List<KanbanTask> tasks) => _guard(() async {
    if (tasks.isEmpty) return;
    await _client.rpc(
      'reorder_kanban_tasks',
      params: {
        'p_tasks': [
          for (final task in tasks)
            {'id': task.id, 'sort_order': task.sortOrder},
        ],
      },
    );
  });

  @override
  Future<List<TaskTag>> getUserTags(String userId) => _guard(
    () async =>
        (await _client
                .from('task_tags')
                .select()
                .eq('owner_id', userId)
                .order('name'))
            .map(TaskTag.fromMap)
            .toList(),
  );

  @override
  Future<TaskTag> createTag(String userId, String name, String colorHex) =>
      _guard(() async {
        final normalized = TaskTag.normalizeHex(colorHex);
        if (normalized == null) {
          throw const AppException(AppErrorMessages.invalidTagColor);
        }
        final row = await _client
            .from('task_tags')
            .insert({'owner_id': userId, 'name': name, 'color_hex': normalized})
            .select()
            .single();
        return TaskTag.fromMap(row);
      });

  @override
  Future<TaskTag> updateTag(TaskTag tag) => _guard(() async {
    final normalized = TaskTag.normalizeHex(tag.colorHex);
    if (normalized == null) {
      throw const AppException(AppErrorMessages.invalidTagColor);
    }
    final row = await _client
        .from('task_tags')
        .update({'name': tag.name, 'color_hex': normalized})
        .eq('id', tag.id)
        .select()
        .single();
    return TaskTag.fromMap(row);
  });

  @override
  Future<void> deleteTag(String tagId) => _guard(() async {
    await _client.from('task_tag_links').delete().eq('tag_id', tagId);
    await _client.from('task_tags').delete().eq('id', tagId);
  });

  @override
  Future<void> attachTagToTask(String taskId, String tagId) => _guard(() async {
    await _client.from('task_tag_links').insert({
      'task_id': taskId,
      'tag_id': tagId,
    });
    await addActivity(taskId, 'tag_added', newValues: {'tag_id': tagId});
  });

  @override
  Future<void> removeTagFromTask(String taskId, String tagId) =>
      _guard(() async {
        await _client
            .from('task_tag_links')
            .delete()
            .eq('task_id', taskId)
            .eq('tag_id', tagId);
        await addActivity(taskId, 'tag_removed', oldValues: {'tag_id': tagId});
      });

  @override
  Future<TaskChecklistItem> createChecklistItem(
    String taskId,
    String title,
    int position,
  ) => _guard(() async {
    final row = await _client
        .from('task_checklist_items')
        .insert({'task_id': taskId, 'title': title, 'position': position})
        .select()
        .single();
    await addActivity(taskId, 'checklist_updated');
    return TaskChecklistItem.fromMap(row);
  });

  @override
  Future<TaskChecklistItem> updateChecklistItem(
    TaskChecklistItem item,
  ) => _guard(() async {
    // The RPC reads the previous state under a lock and logs the actual
    // transition in the same transaction. Repeated completed saves are not progress.
    final row = await _client
        .rpc(
          'update_task_checklist_item',
          params: {
            'p_item_id': item.id,
            'p_title': item.title,
            'p_position': item.position,
            'p_is_completed': item.isCompleted,
          },
        )
        .single();
    return TaskChecklistItem.fromMap(row);
  });

  @override
  Future<void> deleteChecklistItem(String itemId) => _guard(() async {
    await _client.rpc(
      'delete_task_checklist_item',
      params: {'p_item_id': itemId},
    );
  });

  @override
  Future<void> reorderChecklistItems(List<TaskChecklistItem> items) =>
      _guard(() async {
        if (items.isEmpty) return;
        await _client.rpc(
          'reorder_task_checklist',
          params: {
            'p_task_id': items.first.taskId,
            'p_items': [
              for (final item in items)
                {'id': item.id, 'position': item.position},
            ],
          },
        );
      });

  @override
  Future<TaskAttachment> uploadAttachment(
    String taskId,
    String fileName,
    Uint8List bytes,
    String? mimeType,
  ) => _guard(() async {
    final userId = currentUserId;
    if (userId == null) {
      throw const AppException('Sign in to upload attachments.');
    }
    final safeName = fileName.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final path =
        '$userId/$taskId/${DateTime.now().microsecondsSinceEpoch}_$safeName';
    try {
      await _client.storage
          .from(_bucket)
          .uploadBinary(
            path,
            bytes,
            fileOptions: FileOptions(contentType: mimeType, upsert: false),
          );
    } on StorageException {
      throw const AppException(
        'Attachment storage is unavailable. Check the task-attachments bucket.',
      );
    }
    try {
      final row = await _client
          .rpc(
            'register_task_attachment',
            params: {
              'p_task_id': taskId,
              'p_file_name': fileName,
              'p_storage_path': path,
              'p_mime_type': mimeType ?? 'application/octet-stream',
              'p_file_size': bytes.length,
            },
          )
          .single();
      return TaskAttachment.fromMap(row);
    } catch (_) {
      // A lost response may follow a committed transaction.
      // Remove the object only after a query confirms metadata is absent.
      final saved = await _client
          .from('task_attachments')
          .select()
          .eq('task_id', taskId)
          .eq('storage_path', path)
          .maybeSingle();
      if (saved != null) return TaskAttachment.fromMap(saved);
      await _client.storage.from(_bucket).remove([path]);
      rethrow;
    }
  });

  @override
  Future<void> deleteAttachment(TaskAttachment attachment) => _guard(() async {
    await _client.storage.from(_bucket).remove([attachment.storagePath]);
    await _client.from('task_attachments').delete().eq('id', attachment.id);
    await addActivity(
      attachment.taskId,
      'attachment_removed',
      oldValues: {'file_name': attachment.fileName},
    );
  });

  @override
  Future<String> getAttachmentUrl(TaskAttachment attachment) => _guard(
    () async => await _client.storage
        .from(_bucket)
        .createSignedUrl(attachment.storagePath, 60),
  );

  @override
  Future<List<TaskActivity>> getTaskActivity(String taskId) => _guard(
    () async =>
        (await _client
                .from('task_activity_logs')
                .select()
                .eq('task_id', taskId)
                .order('created_at', ascending: false))
            .map(TaskActivity.fromMap)
            .toList(),
  );

  @override
  Future<void> addProgressUpdate(
    String taskId,
    String text, {
    required String requestId,
  }) => _guard(() async {
    final error = TaskActivity.validateProgressText(text);
    if (error != null) throw AppException(error);
    await _client.rpc(
      'add_task_progress_update',
      params: {
        'p_task_id': taskId,
        'p_request_id': requestId,
        'p_text': text.trim(),
      },
    );
  });

  @override
  Future<void> addActivity(
    String taskId,
    String action, {
    Map<String, dynamic> oldValues = const {},
    Map<String, dynamic> newValues = const {},
  }) => _guard(() async {
    await _client.from('task_activity_logs').insert({
      'task_id': taskId,
      'action': action,
      'old_values': oldValues,
      'new_values': newValues,
    });
  });
}
