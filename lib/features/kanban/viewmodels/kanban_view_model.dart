import 'dart:collection';

import 'package:flutter/foundation.dart';

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
  String? _boardId;
  String? _archivedBoardId;
  List<KanbanTask> _tasks = [];
  List<TaskTag> _tags = [];
  bool _isLoading = false, _isSaving = false;
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
    if (_isLoading) return;
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();
    try {
      _boardId = boardId ?? await _repository.getFirstBoardId();
      _archivedBoardId = null;
      if (_boardId == null) {
        _tasks = [];
        _tags = [];
        _archivedBoardId = await _repository.getFirstBoardId(archived: true);
        _errorMessage = _archivedBoardId == null
            ? null
            : 'This board is archived.';
      } else {
        await _reload();
      }
    } catch (error) {
      _errorMessage = error.toString();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> _reload() async {
    final board = _boardId;
    if (board == null) return;
    _tasks = await _repository.getTasks(board);
    final user = _repository.currentUserId;
    _tags = user == null ? [] : await _repository.getUserTags(user);
    _errorMessage = null;
    notifyListeners();
  }

  Future<void> refresh({bool showLoading = true}) async {
    if (_boardId == null) {
      await initialize();
      return;
    }
    if (showLoading) {
      _isLoading = true;
      notifyListeners();
    }
    try {
      await _reload();
    } catch (error) {
      _errorMessage = error.toString();
      notifyListeners();
    } finally {
      if (showLoading) {
        _isLoading = false;
        notifyListeners();
      }
    }
  }

  Future<void> retry() => initialize(_boardId);

  Future<bool> archiveBoard() async {
    final id = _boardId;
    if (id == null || _isSaving) return false;
    _isSaving = true;
    notifyListeners();
    try {
      await _repository.setBoardArchived(id, true);
      _archivedBoardId = id;
      _boardId = null;
      _tasks = [];
      _tags = [];
      _errorMessage = 'This board is archived.';
      _feedbackMessage = 'Board archived';
      return true;
    } catch (error) {
      _errorMessage = error.toString();
      return false;
    } finally {
      _isSaving = false;
      notifyListeners();
    }
  }

  Future<bool> restoreArchivedBoard() async {
    final id = _archivedBoardId;
    if (id == null || _isSaving) return false;
    _isSaving = true;
    notifyListeners();
    try {
      await _repository.setBoardArchived(id, false);
      _boardId = id;
      _archivedBoardId = null;
      await _reload();
      _feedbackMessage = 'Board restored';
      return true;
    } catch (error) {
      _errorMessage = error.toString();
      return false;
    } finally {
      _isSaving = false;
      notifyListeners();
    }
  }

  Future<bool> signIn(String email, String password) async {
    if (email.trim().isEmpty || password.isEmpty) {
      _errorMessage = 'Enter your email and password.';
      notifyListeners();
      return false;
    }
    _isSaving = true;
    _errorMessage = null;
    notifyListeners();
    try {
      await _repository.signIn(email.trim(), password);
      _isSaving = false;
      await initialize();
      return _errorMessage == null;
    } catch (error) {
      _errorMessage = error.toString();
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
  }) async {
    if (_isSaving) return false;
    final previous = _tasks;
    _isSaving = true;
    _errorMessage = null;
    if (optimistic != null) _tasks = optimistic;
    notifyListeners();
    try {
      await operation();
      await _reload();
      _feedbackMessage = feedback;
      return true;
    } catch (error) {
      _tasks = previous;
      _errorMessage = failureMessage ?? error.toString();
      return false;
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
      sortOrder: tasks(status).length,
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
    return _save(() async {
      await _repository.updateTask(
        task.copyWith(
          title: title.trim(),
          description: description.trim(),
          priority: priority,
          status: status,
          sortOrder: status == task.status
              ? task.sortOrder
              : tasks(status).length,
          deadline: deadline,
          clearDeadline: deadline == null,
          completedAt: status == KanbanStatus.completed
              ? (task.completedAt ?? DateTime.now().toUtc())
              : null,
          clearCompletedAt: status != KanbanStatus.completed,
          updatedAt: DateTime.now().toUtc(),
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
    }, 'Task updated successfully');
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
    final target = tasks(
      destination,
    ).where((item) => item.id != taskId).toList();
    final index = (newIndex ?? target.length).clamp(0, target.length);
    target.insert(
      index,
      task.copyWith(
        status: destination,
        completedAt: destination == KanbanStatus.completed
            ? (task.completedAt ?? DateTime.now().toUtc())
            : null,
        clearCompletedAt: destination != KanbanStatus.completed,
      ),
    );
    final targetOrdered = [
      for (var i = 0; i < target.length; i++) target[i].copyWith(sortOrder: i),
    ];
    if (original == destination &&
        targetOrdered[index].sortOrder == task.sortOrder) {
      return true;
    }
    final source = original == destination
        ? <KanbanTask>[]
        : tasks(original).where((item) => item.id != taskId).toList();
    final sourceOrdered = [
      for (var i = 0; i < source.length; i++) source[i].copyWith(sortOrder: i),
    ];
    final reordered = [...targetOrdered, ...sourceOrdered];
    final byId = {for (final item in reordered) item.id: item};
    final optimistic = _tasks.map((item) => byId[item.id] ?? item).toList();
    final ok = await _save(
      () async {
        if (original != destination) {
          await _repository.moveTask(task, destination, index);
        }
        await _repository.reorderTasks(reordered);
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
    );
    if (ok && original != destination) {
      _undo = _UndoAction(task.id, original, task.sortOrder, false);
    }
    return ok;
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
      _errorMessage = 'Enter a valid 6-digit hex color.';
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
      failureMessage: 'Unable to save the tag. Please try again.',
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
      _errorMessage = 'Enter a valid 6-digit hex color.';
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
      failureMessage: 'Unable to save the tag. Please try again.',
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
      failureMessage: 'Unable to delete the tag. Please try again.',
    );
  }

  Future<bool> addTagToTask(String taskId, String tagId) =>
      _save(() => _repository.attachTagToTask(taskId, tagId), 'Tag added');
  Future<bool> removeTagFromTask(String taskId, String tagId) =>
      _save(() => _repository.removeTagFromTask(taskId, tagId), 'Tag removed');

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
}

class _UndoAction {
  const _UndoAction(this.taskId, this.status, this.index, this.wasArchive);
  final String taskId;
  final KanbanStatus status;
  final int index;
  final bool wasArchive;
}
