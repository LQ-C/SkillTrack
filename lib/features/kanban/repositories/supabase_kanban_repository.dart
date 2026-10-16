import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/errors/app_exception.dart';
import '../models/kanban_status.dart';
import '../models/kanban_task.dart';
import '../models/task_activity.dart';
import '../models/task_attachment.dart';
import '../models/task_checklist_item.dart';
import '../models/task_tag.dart';
import 'kanban_repository.dart';
import '../../ai_task_generation/models/generated_task_draft.dart';

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
    final row = await _client
        .from('kanban_tasks')
        .insert(data)
        .select()
        .single();
    final created = KanbanTask.fromMap(row);
    try {
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
    List<GeneratedTaskDraft> tasks,
  ) => _guard(() async {
    if (tasks.isEmpty) return;
    final inserted = await _client
        .from('kanban_tasks')
        .insert([
          for (final task in tasks)
            {
              'board_id': boardId,
              'title': task.title,
              'description': task.description,
              'status': KanbanStatus.todo.value,
              'priority': task.priority,
              'deadline': task.deadline.toIso8601String().split('T').first,
              'sort_order': (task.position + 1) * 1000,
              'is_archived': false,
            },
        ])
        .select('id,sort_order');
    final idsByOrder = <int, String>{};
    for (final row in inserted) {
      final order = (row['sort_order'] as num?)?.toInt();
      final id = row['id'];
      if (order == null ||
          id is! String ||
          id.isEmpty ||
          idsByOrder.containsKey(order)) {
        throw const AppException(AppErrorMessages.saveGeneratedTasksFailed);
      }
      idsByOrder[order] = id;
    }
    if (idsByOrder.length != tasks.length) {
      throw const AppException(AppErrorMessages.saveGeneratedTasksFailed);
    }
    final checklistRows = <Map<String, dynamic>>[];
    for (final task in tasks) {
      final taskId = idsByOrder[(task.position + 1) * 1000];
      if (taskId == null) {
        throw const AppException(AppErrorMessages.saveGeneratedTasksFailed);
      }
      for (var index = 0; index < task.checklist.length; index++) {
        checklistRows.add({
          'task_id': taskId,
          'title': task.checklist[index],
          'position': index,
          'is_completed': false,
        });
      }
    }
    if (checklistRows.isEmpty) return;
    try {
      await _client.from('task_checklist_items').insert(checklistRows);
    } catch (_) {
      try {
        await _client
            .from('kanban_tasks')
            .delete()
            .inFilter('id', idsByOrder.values.toList());
      } catch (_) {
        // Preserve the checklist insertion error if rollback also fails.
      }
      rethrow;
    }
  });

  @override
  Future<KanbanTask> updateTask(KanbanTask task) => _guard(() async {
    final row = await _client
        .from('kanban_tasks')
        .update(
          task.toMap()
            ..remove('id')
            ..remove('board_id'),
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
  Future<void> archiveTask(String taskId, bool archived) => _guard(() async {
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
  Future<void> moveTask(
    KanbanTask task,
    KanbanStatus status,
    int order, {
    DateTime? completedAt,
  }) => _guard(() async {
    await _client
        .from('kanban_tasks')
        .update({
          'status': status.value,
          'sort_order': order,
          'completed_at': status == KanbanStatus.completed
              ? (completedAt ?? DateTime.now().toUtc()).toIso8601String()
              : null,
        })
        .eq('id', task.id);
  });

  @override
  Future<void> reorderTasks(List<KanbanTask> tasks) => _guard(() async {
    for (final task in tasks) {
      await _client
          .from('kanban_tasks')
          .update({'sort_order': task.sortOrder})
          .eq('id', task.id);
    }
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
  Future<TaskChecklistItem> updateChecklistItem(TaskChecklistItem item) =>
      _guard(() async {
        final row = await _client
            .from('task_checklist_items')
            .update({
              'title': item.title,
              'position': item.position,
              'is_completed': item.isCompleted,
              'completed_at': item.completedAt?.toIso8601String(),
            })
            .eq('id', item.id)
            .select()
            .single();
        await addActivity(item.taskId, 'checklist_updated');
        return TaskChecklistItem.fromMap(row);
      });

  @override
  Future<void> deleteChecklistItem(String itemId) => _guard(() async {
    await _client.from('task_checklist_items').delete().eq('id', itemId);
  });

  @override
  Future<void> reorderChecklistItems(List<TaskChecklistItem> items) =>
      _guard(() async {
        for (final item in items) {
          await _client
              .from('task_checklist_items')
              .update({'position': item.position})
              .eq('id', item.id);
        }
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
          .from('task_attachments')
          .insert({
            'task_id': taskId,
            'file_name': fileName,
            'storage_path': path,
            'mime_type': mimeType,
            'file_size_bytes': bytes.length,
          })
          .select()
          .single();
      await addActivity(
        taskId,
        'attachment_added',
        newValues: {'file_name': fileName},
      );
      return TaskAttachment.fromMap(row);
    } catch (_) {
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
