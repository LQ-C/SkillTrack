import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../../../core/errors/app_exception.dart';
import '../../../core/constants/app_constants.dart';
import '../models/kanban_filter.dart';
import '../models/kanban_sort.dart';
import '../models/kanban_status.dart';
import '../models/kanban_task.dart';
import '../models/task_activity.dart';
import '../models/task_attachment.dart';
import '../models/task_checklist_item.dart';
import '../models/task_priority.dart';
import '../models/task_tag.dart';
import '../repositories/kanban_repository.dart';

class KanbanViewModel extends ChangeNotifier {
  KanbanViewModel(this._repository);
  final KanbanRepository _repository;
  static const _sortOrderStep = 1000;
  bool _disposed = false;
  int _activityVersion = 0;
  int get activityVersion => _activityVersion;
  String? _boardId;
  String? _archivedBoardId;
  List<KanbanTask> _tasks = [];
  List<TaskTag> _tags = [];
  bool _isLoading = false, _isSaving = false;
  bool _isRefreshing = false;
  String? _errorMessage, _feedbackMessage, _titleError;
  String _searchQuery = '';
  KanbanFilter _filter = KanbanFilter();
  KanbanSort _sort = KanbanSort.custom;
  _UndoAction? _undo;

  bool get isLoading => _isLoading;
  bool get isSaving => _isSaving;
  String? get errorMessage => _errorMessage;
  String? get feedbackMessage => _feedbackMessage;
  String? get titleError => _titleError;
  String get searchQuery => _searchQuery;
  KanbanFilter get activeFilter => _filter;
  KanbanSort get activeSort => _sort;
  String? get boardId => _boardId;
  bool get isBoardArchived => _archivedBoardId != null;
  bool get isSignedIn => _repository.currentUserId != null;
  List<KanbanTask> get allTasks => UnmodifiableListView(_tasks);
  List<TaskTag> get availableTags => UnmodifiableListView(_tags);
  bool get hasActiveFilters => _filter.isActive;
  bool get isBoardEmpty => _tasks.where((task) => !task.isArchived).isEmpty;
  bool get isResultEmpty =>
      KanbanStatus.values.every((status) => visibleTasks(status).isEmpty);
  int get totalTaskCount => _tasks.where((task) => !task.isArchived).length;
  int get completedTaskCount =>
      _tasks.where((task) => !task.isArchived && task.isCompleted).length;
  int get inProgressTaskCount => _tasks
      .where(
        (task) => !task.isArchived && task.status == KanbanStatus.inProgress,
      )
      .length;
  int get overdueTaskCount =>
      _tasks.where((task) => !task.isArchived && task.isOverdue).length;
  int get dueSoonTaskCount =>
      _tasks.where((task) => !task.isArchived && task.isDueSoon).length;
  double get projectProgress =>
      totalTaskCount == 0 ? 0 : completedTaskCount / totalTaskCount;
  int get projectProgressPercentage => (projectProgress * 100).round();

  List<KanbanTask> tasks(KanbanStatus status) => UnmodifiableListView(
    _tasks.where((task) => !task.isArchived && task.status == status).toList()
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder)),
  );

  List<KanbanTask> visibleTasks(KanbanStatus status) {
    final query = _searchQuery.trim().toLowerCase();
    final list = _tasks.where((task) {
      if (task.isArchived || task.status != status) return false;
      if (query.isNotEmpty &&
          ![
            task.title,
            task.description,
            ...task.tags.map((tag) => tag.name),
          ].any((value) => value.toLowerCase().contains(query))) {
        return false;
      }
      if (_filter.statuses.isNotEmpty &&
          !_filter.statuses.contains(task.status)) {
        return false;
      }
      if (_filter.priorities.isNotEmpty &&
          !_filter.priorities.contains(task.priority)) {
        return false;
      }
      if (_filter.tagIds.isNotEmpty &&
          !task.tags.any((tag) => _filter.tagIds.contains(tag.id))) {
        return false;
      }
      if (_filter.overdueOnly && !task.isOverdue) return false;
      if (_filter.completedOnly && !task.isCompleted) return false;
      if (_filter.deadlineStart != null &&
          (task.deadline == null ||
              task.deadline!.isBefore(_filter.deadlineStart!))) {
        return false;
      }
      if (_filter.deadlineEnd != null &&
          (task.deadline == null ||
              task.deadline!.isAfter(
                _filter.deadlineEnd!.add(const Duration(days: 1)),
              ))) {
        return false;
      }
      return true;
    }).toList();
    list.sort(
      (a, b) => switch (_sort) {
        KanbanSort.custom => a.sortOrder.compareTo(b.sortOrder),
        KanbanSort.nearestDeadline => (a.deadline ?? DateTime(9999)).compareTo(
          b.deadline ?? DateTime(9999),
        ),
        KanbanSort.highestPriority => b.priority.index.compareTo(
          a.priority.index,
        ),
        KanbanSort.recentlyCreated => b.createdAt.compareTo(a.createdAt),
        KanbanSort.recentlyUpdated => b.updatedAt.compareTo(a.updatedAt),
      },
    );
    return UnmodifiableListView(list);
  }

  Future<void> initialize([String? boardId]) async {
    if (_disposed || _isLoading) return;
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();
    try {
      final id = boardId ?? await _repository.getFirstBoardId();
      if (_disposed) return;
      _boardId = id;
      _archivedBoardId = null;
      if (_boardId == null) {
        _tasks = [];
        _tags = [];
        _archivedBoardId = await _repository.getFirstBoardId(archived: true);
        if (_disposed) return;
        _errorMessage = _archivedBoardId == null
            ? null
            : 'This board is archived.';
      } else {
        await _reload();
      }
    } catch (error) {
      if (!_disposed) _errorMessage = AppException.messageFor(error);
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> _reload() async {
    final board = _boardId;
    if (_disposed || board == null) return;
    final user = _repository.currentUserId;
    final (loaded, tags) = await (
      _repository.getTasks(board),
      user == null ? Future.value(<TaskTag>[]) : _repository.getUserTags(user),
    ).wait;
    if (_disposed || board != _boardId) return;
    _tasks = loaded;
    _tags = tags;
    _errorMessage = null;
    notifyListeners();
  }

  Future<void> refresh({bool showLoading = true}) async {
    if (_disposed || _isLoading || _isRefreshing) return;
    if (_boardId == null) {
      await initialize();
      return;
    }
    _isRefreshing = true;
    if (showLoading) {
      _isLoading = true;
      notifyListeners();
    }
    try {
      await _reload();
    } catch (error) {
      if (!_disposed) _errorMessage = AppException.messageFor(error);
      notifyListeners();
    } finally {
      _isRefreshing = false;
      if (showLoading) {
        _isLoading = false;
        notifyListeners();
      }
    }
  }

  Future<void> retry() => initialize(_boardId);

  Future<bool> archiveBoard() async {
    final id = _boardId;
    if (_disposed || id == null || _isSaving) return false;
    _isSaving = true;
    notifyListeners();
    try {
      await _repository.setBoardArchived(id, true);
      if (_disposed) return false;
      _archivedBoardId = id;
      _boardId = null;
      _tasks = [];
      _tags = [];
      _errorMessage = 'This board is archived.';
      _feedbackMessage = 'Board archived';
      return true;
    } catch (error) {
      if (!_disposed) _errorMessage = AppException.messageFor(error);
      return false;
    } finally {
      _isSaving = false;
      notifyListeners();
    }
  }

  Future<bool> restoreArchivedBoard() async {
    final id = _archivedBoardId;
    if (_disposed || id == null || _isSaving) return false;
    _isSaving = true;
    notifyListeners();
    try {
      await _repository.setBoardArchived(id, false);
      if (_disposed) return false;
      _boardId = id;
      _archivedBoardId = null;
      await _reload();
      if (_disposed) return false;
      _feedbackMessage = 'Board restored';
      return true;
    } catch (error) {
      if (!_disposed) _errorMessage = AppException.messageFor(error);
      return false;
    } finally {
      _isSaving = false;
      notifyListeners();
    }
  }

  Future<bool> signIn(String email, String password) async {
    if (_disposed || _isSaving) return false;
    if (email.trim().isEmpty || password.isEmpty) {
      _errorMessage = AppErrorMessages.credentialsRequired;
      notifyListeners();
      return false;
    }
    _isSaving = true;
    _errorMessage = null;
    notifyListeners();
    try {
      await _repository.signIn(email.trim(), password);
      if (_disposed) return false;
      await initialize();
      return !_disposed && _errorMessage == null;
    } catch (error) {
      if (!_disposed) _errorMessage = AppException.messageFor(error);
      return false;
    } finally {
      _isSaving = false;
      notifyListeners();
    }
  }

  void setSearchQuery(String query) {
    if (query == _searchQuery) return;
    _searchQuery = query;
    notifyListeners();
  }

  void applyFilter(KanbanFilter filter) {
    _filter = filter;
    notifyListeners();
  }

  void clearFilters() {
    if (!_filter.isActive) return;
    _filter = KanbanFilter();
    notifyListeners();
  }

  void setSort(KanbanSort sort) {
    if (sort == _sort) return;
    _sort = sort;
    notifyListeners();
  }

  void clearError() {
    if (_errorMessage == null) return;
    _errorMessage = null;
    notifyListeners();
  }

  void clearFeedbackMessage() {
    if (_feedbackMessage == null) return;
    _feedbackMessage = null;
    notifyListeners();
  }

  Future<bool> _save(
    Future<void> Function() operation,
    String feedback, {
    List<KanbanTask>? optimistic,
    String? failureMessage,
    bool reconcileOnFailure = false,
  }) async {
    if (_disposed || _isSaving) return false;
    final previous = _tasks;
    _isSaving = true;
    _errorMessage = null;
    if (optimistic != null) _tasks = optimistic;
    notifyListeners();
    var committed = false;
    try {
      await operation();
      committed = true;
      if (_disposed) return false;
      _activityVersion++;
      await _reload();
      if (_disposed) return false;
      _feedbackMessage = feedback;
      return true;
    } catch (error) {
      if (_disposed) return false;
      if (!committed) {
        _tasks = previous;
        if (reconcileOnFailure) {
          try {
            await _reload();
          } catch (_) {
            // Preserve the last known state if the network is unavailable.
          }
          if (_disposed) return false;
        }
      }
      _errorMessage = committed
          ? AppErrorMessages.savedRefreshFailed
          : failureMessage ?? AppException.messageFor(error);
      if (committed) _feedbackMessage = feedback;
      return committed;
    } finally {
      _isSaving = false;
      notifyListeners();
    }
  }

  Future<bool> createTask({
    required String title,
    String description = '',
    KanbanStatus status = KanbanStatus.todo,
    TaskPriority priority = TaskPriority.medium,
    DateTime? deadline,
    List<String> tagIds = const [],
    List<String> checklist = const [],
  }) async {
    if (title.trim().isEmpty) {
      _titleError = 'Task title is required';
      notifyListeners();
      return false;
    }
    if (_boardId == null) {
      _errorMessage = 'No project board is available.';
      notifyListeners();
      return false;
    }
    _titleError = null;
    final now = DateTime.now().toUtc();
    final task = KanbanTask(
      id: '',
      boardId: _boardId!,
      title: title.trim(),
      description: description.trim(),
      status: status,
      priority: priority,
      deadline: deadline,
      sortOrder: _nextSortOrder(status),
      completedAt: status == KanbanStatus.completed ? now : null,
      createdAt: now,
      updatedAt: now,
    );
    return _save(() async {
      final created = await _repository.createTask(task);
      try {
        for (final tagId in tagIds) {
          await _repository.attachTagToTask(created.id, tagId);
        }
        for (var index = 0; index < checklist.length; index++) {
          if (checklist[index].trim().isNotEmpty) {
            await _repository.createChecklistItem(
              created.id,
              checklist[index].trim(),
              index,
            );
          }
        }
      } catch (_) {
        await _repository.deleteTask(created.id);
        rethrow;
      }
      _tasks = [..._tasks, created];
    }, 'Task created successfully');
  }

  Future<bool> updateTask(
    KanbanTask task, {
    required String title,
    required String description,
    required KanbanStatus status,
    required TaskPriority priority,
    DateTime? deadline,
    List<String>? tagIds,
  }) async {
    if (title.trim().isEmpty) {
      _titleError = 'Task title is required';
      notifyListeners();
      return false;
    }
    _titleError = null;
    return _save(
      () async {
        final current = status == task.status
            ? task
            : await _repository.moveTask(task, status, _nextSortOrder(status));
        await _repository.updateTask(
          current.copyWith(
            title: title.trim(),
            description: description.trim(),
            priority: priority,
            deadline: deadline,
            clearDeadline: deadline == null,
          ),
        );
        if (status != task.status) {
          await _repository.addActivity(
            task.id,
            status == KanbanStatus.completed
                ? 'completed'
                : task.status == KanbanStatus.completed
                ? 'reopened'
                : 'moved',
            oldValues: {'status': task.status.value},
            newValues: {'status': status.value},
          );
        }
        if (tagIds != null) {
          final oldIds = task.tags.map((tag) => tag.id).toSet();
          final newIds = tagIds.toSet();
          for (final id in oldIds.difference(newIds)) {
            await _repository.removeTagFromTask(task.id, id);
          }
          for (final id in newIds.difference(oldIds)) {
            await _repository.attachTagToTask(task.id, id);
          }
        }
      },
      'Task updated successfully',
      reconcileOnFailure: true,
    );
  }

  Future<bool> moveTask(
    String taskId,
    KanbanStatus destination, {
    int? newIndex,
  }) async {
    final task = _tasks.where((item) => item.id == taskId).firstOrNull;
    if (task == null) return false;
    final original = task.status;
    if (original == destination && newIndex == null) return true;
    final originalTasks = tasks(original);
    final originalIndex = originalTasks.indexWhere((item) => item.id == taskId);
    final previousTarget = tasks(destination);
    final target = previousTarget.where((item) => item.id != taskId).toList();
    final index = (newIndex ?? target.length).clamp(0, target.length);
    if (original == destination && index == originalIndex) return true;
    final candidateOrder = _insertionOrder(target, index);
    final moved = task.copyWith(
      status: destination,
      sortOrder: candidateOrder ?? (index + 1) * _sortOrderStep,
      completedAt: destination == KanbanStatus.completed
          ? (task.completedAt ?? DateTime.now().toUtc())
          : null,
      clearCompletedAt: destination != KanbanStatus.completed,
    );
    target.insert(index, moved);
    final normalized = candidateOrder == null;
    final targetOrdered = normalized
        ? [
            for (var i = 0; i < target.length; i++)
              target[i].copyWith(sortOrder: (i + 1) * _sortOrderStep),
          ]
        : target;
    final updated = targetOrdered[index];
    final byId = {for (final item in targetOrdered) item.id: item};
    final optimistic = _tasks.map((item) => byId[item.id] ?? item).toList();
    final ok = await _save(
      () async {
        KanbanTask? persisted;
        try {
          if (original != destination) {
            persisted = await _repository.moveTask(
              task,
              destination,
              updated.sortOrder,
              completedAt: updated.completedAt,
            );
          }
          if (normalized) {
            await _repository.reorderTasks(targetOrdered);
          } else if (original == destination) {
            await _repository.reorderTasks([updated]);
          }
          if (original != destination) {
            await _repository.addActivity(
              task.id,
              destination == KanbanStatus.completed
                  ? 'completed'
                  : original == KanbanStatus.completed
                  ? 'reopened'
                  : 'moved',
              oldValues: {'status': original.value, 'position': originalIndex},
              newValues: {'status': destination.value, 'position': index},
            );
          }
        } catch (_) {
          try {
            if (persisted != null) {
              // Reordering may have changed updated_at after the status RPC.
              final latest = (await _repository.getTasks(
                task.boardId,
              )).where((item) => item.id == task.id).first;
              final restored = await _repository.moveTask(
                latest,
                original,
                task.sortOrder,
                completedAt: task.completedAt,
              );
              if (original == KanbanStatus.inProgress && !task.isTracking) {
                await _repository.setTaskTimerPaused(restored, true);
              }
            }
            if (normalized || original == destination) {
              await _repository.reorderTasks(previousTarget);
            }
          } catch (_) {
            // Keep the original failure; the in-memory state is rolled back by _save.
          }
          rethrow;
        }
      },
      original == destination
          ? 'Task reordered'
          : destination == KanbanStatus.completed
          ? 'Task marked as completed'
          : original == KanbanStatus.completed
          ? 'Task reopened'
          : 'Task moved',
      optimistic: optimistic,
      failureMessage: 'Unable to move the task. Please try again.',
      reconcileOnFailure: true,
    );
    if (ok && original != destination) {
      _undo = _UndoAction(task.id, original, originalIndex, false);
    }
    return ok;
  }

  Future<bool> setTaskTimerPaused(String taskId, bool paused) async {
    final task = _tasks.where((item) => item.id == taskId).firstOrNull;
    if (task == null ||
        task.isArchived ||
        task.status != KanbanStatus.inProgress) {
      return false;
    }
    if (_disposed || _isSaving) return false;
    if (paused == !task.isTracking) return true;
    return _save(
      () async {
        final updated = await _repository.setTaskTimerPaused(task, paused);
        _tasks = [
          for (final item in _tasks) item.id == taskId ? updated : item,
        ];
      },
      paused ? 'Timer paused' : 'Timer resumed',
      reconcileOnFailure: true,
    );
  }

  int _nextSortOrder(KanbanStatus status) {
    final column = tasks(status);
    return _insertionOrder(column, column.length)!;
  }

  int? _insertionOrder(List<KanbanTask> tasks, int index) {
    if (tasks.isEmpty) return _sortOrderStep;
    if (index == 0) {
      final first = tasks.first.sortOrder;
      return first > 1 ? first ~/ 2 : null;
    }
    if (index == tasks.length) return tasks.last.sortOrder + _sortOrderStep;
    final before = tasks[index - 1].sortOrder;
    final after = tasks[index].sortOrder;
    return after - before > 1 ? before + (after - before) ~/ 2 : null;
  }

  Future<bool> reorderTask(String taskId, KanbanStatus status, int newIndex) =>
      moveTask(taskId, status, newIndex: newIndex);
  Future<bool> completeTask(String taskId) =>
      moveTask(taskId, KanbanStatus.completed);
  Future<bool> reopenTask(String taskId, KanbanStatus status) =>
      moveTask(taskId, status);

  Future<bool> archiveTask(String taskId) async {
    final task = _tasks.where((item) => item.id == taskId).firstOrNull;
    if (task == null) return false;
    final ok = await _save(
      () => _repository.archiveTask(taskId, true),
      'Task archived',
      reconcileOnFailure: true,
      optimistic: _tasks
          .map(
            (item) =>
                item.id == taskId ? item.copyWith(isArchived: true) : item,
          )
          .toList(),
    );
    if (ok) _undo = _UndoAction(taskId, task.status, task.sortOrder, true);
    return ok;
  }

  Future<bool> restoreTask(String taskId) =>
      _save(() => _repository.archiveTask(taskId, false), 'Task restored');
  Future<bool> deleteTask(String taskId) =>
      _save(() => _repository.deleteTask(taskId), 'Task deleted');
  Future<bool> undoLastAction() async {
    final action = _undo;
    if (action == null) return false;
    _undo = null;
    return action.wasArchive
        ? restoreTask(action.taskId)
        : moveTask(action.taskId, action.status, newIndex: action.index);
  }

  Future<bool> duplicateTask(KanbanTask task) => createTask(
    title: '${task.title} (copy)',
    description: task.description,
    status: task.status,
    priority: task.priority,
    deadline: task.deadline,
    tagIds: task.tags.map((tag) => tag.id).toList(),
    checklist: task.checklistItems.map((item) => item.title).toList(),
  );

  bool _tagExists(String name, {String? exceptId}) => _tags.any(
    (tag) =>
        tag.id != exceptId &&
        tag.name.toLowerCase() == name.trim().toLowerCase(),
  );
  Future<bool> createTag(String name, String colorHex) async {
    final userId = _repository.currentUserId;
    if (name.trim().isEmpty) {
      _errorMessage = 'Tag name is required.';
      notifyListeners();
      return false;
    }
    if (_tagExists(name)) {
      _errorMessage = 'A tag with this name already exists.';
      notifyListeners();
      return false;
    }
    final normalized = TaskTag.normalizeHex(colorHex);
    if (normalized == null) {
      _errorMessage = AppErrorMessages.invalidTagColor;
      notifyListeners();
      return false;
    }
    if (userId == null) {
      _errorMessage = 'Sign in to create tags.';
      notifyListeners();
      return false;
    }
    return _save(
      () async {
        await _repository.createTag(userId, name.trim(), normalized);
      },
      'Tag created',
      failureMessage: AppErrorMessages.saveTagFailed,
    );
  }

  Future<bool> updateTag(TaskTag tag, String name, String colorHex) async {
    if (_repository.currentUserId == null) {
      _errorMessage = 'Sign in to edit tags.';
      notifyListeners();
      return false;
    }
    if (name.trim().isEmpty) {
      _errorMessage = 'Tag name is required.';
      notifyListeners();
      return false;
    }
    if (_tagExists(name, exceptId: tag.id)) {
      _errorMessage = 'A tag with this name already exists.';
      notifyListeners();
      return false;
    }
    final normalized = TaskTag.normalizeHex(colorHex);
    if (normalized == null) {
      _errorMessage = AppErrorMessages.invalidTagColor;
      notifyListeners();
      return false;
    }
    return _save(
      () async {
        await _repository.updateTag(
          tag.copyWith(name: name.trim(), colorHex: normalized),
        );
      },
      'Tag updated',
      failureMessage: AppErrorMessages.saveTagFailed,
    );
  }

  Future<bool> deleteTag(String tagId) async {
    if (_repository.currentUserId == null) {
      _errorMessage = 'Sign in to manage tags.';
      notifyListeners();
      return false;
    }
    return _save(
      () => _repository.deleteTag(tagId),
      'Tag deleted',
      failureMessage: AppErrorMessages.deleteTagFailed,
    );
  }

  Future<bool> createChecklistItem(String taskId, String title) async {
    if (title.trim().isEmpty) return false;
    final task = _tasks.where((item) => item.id == taskId).firstOrNull;
    if (task == null) return false;
    return _save(() async {
      await _repository.createChecklistItem(
        taskId,
        title.trim(),
        task.checklistItems.length,
      );
    }, 'Checklist item added');
  }

  Future<bool> toggleChecklistItem(TaskChecklistItem item) => _save(() async {
    await _repository.updateChecklistItem(
      item.copyWith(
        isCompleted: !item.isCompleted,
        completedAt: item.isCompleted ? null : DateTime.now().toUtc(),
        clearCompletedAt: item.isCompleted,
      ),
    );
  }, 'Checklist updated');
  Future<bool> updateChecklistItem(TaskChecklistItem item, String title) async {
    if (title.trim().isEmpty) return false;
    return _save(() async {
      await _repository.updateChecklistItem(item.copyWith(title: title.trim()));
    }, 'Checklist updated');
  }

  Future<bool> deleteChecklistItem(TaskChecklistItem item) => _save(
    () => _repository.deleteChecklistItem(item.id),
    'Checklist item deleted',
  );
  Future<bool> reorderChecklistItems(
    String taskId,
    int oldIndex,
    int newIndex,
  ) async {
    final task = _tasks.where((item) => item.id == taskId).firstOrNull;
    if (task == null) return false;
    final list = task.checklistItems.toList();
    if (oldIndex < 0 || oldIndex >= list.length) return false;
    list.insert(newIndex.clamp(0, list.length - 1), list.removeAt(oldIndex));
    return _save(
      () => _repository.reorderChecklistItems([
        for (var i = 0; i < list.length; i++) list[i].copyWith(position: i),
      ]),
      'Checklist reordered',
    );
  }

  Future<bool> uploadAttachment(
    String taskId,
    String fileName,
    Uint8List bytes,
    String? mimeType,
  ) => _save(() async {
    if (bytes.isEmpty || bytes.length > AppLimits.maxAttachmentBytes) {
      throw const AppException(AppErrorMessages.attachmentTooLarge);
    }
    await _repository.uploadAttachment(taskId, fileName, bytes, mimeType);
  }, 'Attachment uploaded');
  Future<bool> deleteAttachment(TaskAttachment attachment) => _save(
    () => _repository.deleteAttachment(attachment),
    'Attachment deleted',
  );
  Future<String> getAttachmentUrl(TaskAttachment attachment) =>
      _repository.getAttachmentUrl(attachment);
  Future<List<TaskActivity>> getTaskActivity(String taskId) =>
      _repository.getTaskActivity(taskId);
  Future<bool> resumeTask(String taskId) async {
    if (_disposed || _isSaving) return false;
    final index = _tasks.indexWhere((task) => task.id == taskId);
    if (index < 0 || !_tasks[index].isStalled) return false;
    _isSaving = true;
    notifyListeners();
    try {
      final resumed = await _repository.resumeTask(_tasks[index]);
      if (_disposed) return false;
      _tasks = List.of(_tasks)..[index] = resumed;
      _feedbackMessage = 'Task resumed';
      _activityVersion++;
      return true;
    } catch (error) {
      if (!_disposed) _errorMessage = AppException.messageFor(error);
      return false;
    } finally {
      _isSaving = false;
      notifyListeners();
    }
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class _UndoAction {
  const _UndoAction(this.taskId, this.status, this.index, this.wasArchive);
  final String taskId;
  final KanbanStatus status;
  final int index;
  final bool wasArchive;
}
