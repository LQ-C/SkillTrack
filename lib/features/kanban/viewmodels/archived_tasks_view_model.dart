import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../../../core/errors/app_exception.dart';
import '../../../core/utils/retryable_write.dart';
import '../models/kanban_task.dart';
import '../repositories/kanban_repository.dart';

class ArchivedTasksViewModel extends ChangeNotifier {
  ArchivedTasksViewModel(this._repository);

  final KanbanRepository _repository;
  final _restoreWrites = RetryableWrite<KanbanTask>();
  bool _disposed = false;
  String? _boardId;
  List<KanbanTask> _tasks = [];
  bool _isLoading = false;
  bool _isSaving = false;
  bool _sortByTitle = false;
  bool _hasChanges = false;
  String _searchQuery = '';
  String? _errorMessage;
  String? _feedbackMessage;

  bool get isLoading => _isLoading;
  bool get isSaving => _isSaving;
  bool get hasChanges => _hasChanges;
  bool get sortByTitle => _sortByTitle;
  String? get errorMessage => _errorMessage;
  String? get feedbackMessage => _feedbackMessage;
  String get searchQuery => _searchQuery;
  bool get isEmpty => _tasks.isEmpty;
  bool get isSearchEmpty => _tasks.isNotEmpty && visibleTasks.isEmpty;
  UnmodifiableListView<KanbanTask> get archivedTasks =>
      UnmodifiableListView(_tasks);

  List<KanbanTask> get visibleTasks {
    final query = _searchQuery.trim().toLowerCase();
    final list = _tasks
        .where(
          (task) =>
              query.isEmpty ||
              [
                task.title,
                task.description,
                ...task.tags.map((tag) => tag.name),
              ].any((value) => value.toLowerCase().contains(query)),
        )
        .toList();
    list.sort(
      _sortByTitle
          ? (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase())
          : (a, b) => b.updatedAt.compareTo(a.updatedAt),
    );
    return UnmodifiableListView(list);
  }

  Future<void> loadArchivedTasks(String boardId) async {
    if (_disposed || _isLoading) return;
    _boardId = boardId;
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();
    try {
      if (boardId.trim().isEmpty) {
        throw StateError('Board unavailable.');
      }
      final loaded = await _repository.getArchivedTasks(boardId);
      if (_disposed) return;
      _tasks = loaded
          .where((task) => task.isArchived && task.boardId == boardId)
          .toList();
    } catch (_) {
      if (_disposed) return;
      _errorMessage = AppErrorMessages.loadArchivedTasksFailed;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> refresh() async {
    final boardId = _boardId;
    if (boardId != null) await loadArchivedTasks(boardId);
  }

  Future<void> retry() => refresh();

  void setSearchQuery(String query) {
    if (_searchQuery == query) return;
    _searchQuery = query;
    notifyListeners();
  }

  void sortRecentlyArchived() {
    _sortByTitle = false;
    notifyListeners();
  }

  void sortByTaskTitle() {
    _sortByTitle = true;
    notifyListeners();
  }

  Future<bool> restoreTask(String taskId) async {
    final task = _tasks.where((task) => task.id == taskId).firstOrNull;
    if (_disposed || _isSaving || task == null) return false;
    _isSaving = true;
    _errorMessage = null;
    notifyListeners();
    try {
      await _restore(task);
      if (_disposed) return false;
      _tasks = _tasks.where((task) => task.id != taskId).toList();
      _hasChanges = true;
      _feedbackMessage = 'Task restored';
      return true;
    } catch (_) {
      if (_disposed) return false;
      _errorMessage = 'Unable to restore the task. Please try again.';
      return false;
    } finally {
      _isSaving = false;
      notifyListeners();
    }
  }

  Future<KanbanTask> _restore(KanbanTask task) => _restoreWrites.run((
    user: _repository.currentUserId,
    board: task.boardId,
    task: task.id,
  ), (id) => _repository.saveTaskArchive(task, false, requestId: id));

  Future<bool> restoreAllTasks() async {
    if (_disposed || _isSaving || _tasks.isEmpty) return false;
    _isSaving = true;
    _errorMessage = null;
    notifyListeners();
    final pending = List<KanbanTask>.of(_tasks);
    var restored = 0;
    try {
      for (final task in pending) {
        try {
          await _restore(task);
          restored++;
          _hasChanges = true;
        } catch (_) {
          // Continue so one failed task does not block the others.
        }
      }
      await refresh();
      if (_disposed) return false;
      if (restored == pending.length && _errorMessage == null) {
        _feedbackMessage = 'All tasks restored';
        return true;
      }
      _errorMessage =
          '$restored of ${pending.length} tasks restored. '
          'Please try the remaining tasks again.';
      return false;
    } finally {
      _isSaving = false;
      notifyListeners();
    }
  }

  Future<bool> deleteTaskPermanently(String taskId) async {
    if (_disposed || _isSaving || !_tasks.any((task) => task.id == taskId)) {
      return false;
    }
    _isSaving = true;
    _errorMessage = null;
    notifyListeners();
    try {
      await _repository.deleteTask(taskId);
      if (_disposed) return false;
      _tasks = _tasks.where((task) => task.id != taskId).toList();
      _hasChanges = true;
      _feedbackMessage = 'Task deleted permanently';
      return true;
    } catch (_) {
      if (_disposed) return false;
      _errorMessage = 'Unable to delete the task. Please try again.';
      return false;
    } finally {
      _isSaving = false;
      notifyListeners();
    }
  }

  void clearError() {
    _errorMessage = null;
    notifyListeners();
  }

  void clearFeedbackMessage() {
    _feedbackMessage = null;
    notifyListeners();
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
