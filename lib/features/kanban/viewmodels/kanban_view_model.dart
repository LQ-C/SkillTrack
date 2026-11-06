import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../../../core/utils/date_formatter.dart';
import '../../../core/utils/operation_id.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/constants/app_constants.dart';
import '../../projects/models/project_milestone.dart';
import '../../projects/repositories/project_repository.dart';
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
  KanbanViewModel(
    this._repository, {
    ProjectRepository? projectRepository,
    String? projectId,
    DateTime Function()? clock,
  }) : _projectRepository = projectRepository,
       _projectId = projectId,
       _clock = clock ?? DateTime.now;
  final DateTime Function() _clock;

  DateTime get malaysiaNow => DateFormatter.malaysiaTime(_clock());

  String? manualDeadlineError(
    DateTime? deadline, {
    required bool hasTime,
    KanbanTask? original,
  }) {
    if (deadline == null) return null;
    if (original != null &&
        original.deadline?.isAtSameMomentAs(deadline) == true &&
        original.hasDeadlineTime == hasTime) {
      return null;
    }

    final now = _clock();
    final today = DateFormatter.today(now: now);
    if (deadline.isBefore(DateFormatter.fromMalaysia(today))) {
      return AppErrorMessages.deadlineDatePassed;
    }
    if (hasTime && !deadline.isAfter(now)) {
      return AppErrorMessages.deadlineTimePassed;
    }
    return null;
  }

  final ProjectRepository? _projectRepository;
  final String? _projectId;
  List<ProjectMilestone> _milestones = [];
  bool _milestoneBoardWritable = false, _isCreatingMilestone = false;
  String? _milestoneError, _milestoneRequestId, _milestoneRequestTitle;
  String? _milestoneRequestBoard;
  bool get isCreatingMilestone => _isCreatingMilestone;
  String? get milestoneError => _milestoneError;
  bool get canCreateMilestone =>
      !_disposed &&
      !_isLoading &&
      !_isSaving &&
      !_isCreatingMilestone &&
      _milestoneBoardWritable &&
      !isBoardArchived &&
      _boardId != null &&
      isSignedIn &&
      _projectRepository?.currentUserId == _repository.currentUserId;

  Future<ProjectMilestone?> createMilestone(String name) async {
    if (_disposed || _isCreatingMilestone) return null;
    _milestoneError = ProjectMilestone.validateTitle(name);
    if (_milestoneError != null || !canCreateMilestone) {
      _milestoneError ??= AppErrorMessages.milestoneBoardUnavailable;
      notifyListeners();
      return null;
    }
    final title = name.trim();
    final board = _boardId!;
    final user = _repository.currentUserId;
    if (_milestoneRequestTitle != title || _milestoneRequestBoard != board) {
      _milestoneRequestId = createOperationId();
      _milestoneRequestTitle = title;
      _milestoneRequestBoard = board;
    }
    _isCreatingMilestone = true;
    notifyListeners();
    try {
      final created = await _projectRepository!.createMilestone(
        boardId: board,
        title: title,
        requestId: _milestoneRequestId!,
      );
      if (_disposed || board != _boardId || user != _repository.currentUserId) {
        return null;
      }
      _milestones = [..._milestones.where((m) => m.id != created.id), created]
        ..sort((a, b) {
          final order = a.position.compareTo(b.position);
          return order == 0 ? a.id.compareTo(b.id) : order;
        });
      _milestoneRequestId = _milestoneRequestTitle = _milestoneRequestBoard =
          null;
      return created;
    } catch (error) {
      if (!_disposed) {
        _milestoneError = AppException.messageFor(
          error,
          fallback: AppErrorMessages.createMilestoneFailed,
        );
      }
      return null;
    } finally {
      _isCreatingMilestone = false;
      notifyListeners();
    }
  }

  List<ProjectMilestone> get availableMilestones =>
      UnmodifiableListView(_milestones);
  String? milestoneTitle(String? id) =>
      _milestones.where((m) => m.id == id).firstOrNull?.title;
  ({int completed, int total}) milestoneProgress(String id) {
    final tasks = _tasks.where((t) => !t.isArchived && t.milestoneId == id);
    return (
      completed: tasks.where((t) => t.isCompleted).length,
      total: tasks.length,
    );
  }

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
      if ((_filter.statuses.isNotEmpty || _filter.includeStalled) &&
          !_filter.statuses.contains(task.status) &&
          !(_filter.includeStalled && task.isStalled)) {
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
      if (_filter.milestoneId != null &&
          task.milestoneId != _filter.milestoneId) {
        return false;
      }
      if (_filter.noMilestoneOnly && task.milestoneId != null) return false;
      if (_filter.overdueOnly && !task.isOverdue) return false;
      if (_filter.completedOnly && !task.isCompleted) return false;
      if (_filter.deadlineStart != null &&
          (task.deadline == null ||
              task.deadline!.isBefore(
                DateFormatter.fromMalaysia(
                  DateFormatter.dateOnly(_filter.deadlineStart!),
                ),
              ))) {
        return false;
      }
      if (_filter.deadlineEnd != null &&
          (task.deadline == null ||
              !task.deadline!.isBefore(
                DateFormatter.fromMalaysia(
                  DateTime(
                    _filter.deadlineEnd!.year,
                    _filter.deadlineEnd!.month,
                    _filter.deadlineEnd!.day + 1,
                  ),
                ),
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

  String? _focusedTaskId;
  ({KanbanTask task, List<String>? tags, String id})? _pendingEdit;

  Future<void> initialize([String? boardId, String? taskId]) async {
    if (_disposed || _isLoading) return;
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();
    try {
      final id = boardId ?? await _repository.getFirstBoardId();
      if (_disposed) return;
      _boardId = id;
      _focusedTaskId = taskId;
      _archivedBoardId = null;
      if (_boardId == null) {
        _tasks = [];
        _tags = [];
        _milestones = [];
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

  Future<void> _reload({String? taskId, bool catalogsOnly = false}) async {
    final board = _boardId;
    if (_disposed || board == null) return;
    final user = _repository.currentUserId;
    final focus = taskId ?? _focusedTaskId;
    final (loaded, tags, milestones, writable) = await (
      catalogsOnly ? Future.value(_tasks) : _loadTasks(board, focus),
      user == null ? Future.value(<TaskTag>[]) : _repository.getUserTags(user),
      _projectRepository != null && _projectId != null
          ? _projectRepository.getProjectMilestones(_projectId)
          : Future.value(<ProjectMilestone>[]),
      _projectRepository != null && _projectId != null
          ? _projectRepository.canCreateMilestone(
              projectId: _projectId,
              boardId: board,
            )
          : Future.value(false),
    ).wait;
    if (_disposed || board != _boardId || user != _repository.currentUserId) {
      return;
    }
    if (!catalogsOnly) {
      _tasks = taskId != null && _focusedTaskId == null
          ? [
              for (final task in _tasks)
                if (task.id != taskId) task,
              ...loaded,
            ]
          : loaded;
    }
    _milestones = milestones;
    _milestoneBoardWritable = writable;
    if (_filter.milestoneId != null &&
        _projectRepository != null &&
        !_milestones.any((m) => m.id == _filter.milestoneId)) {
      _filter = _filter.copyWith(clearMilestone: true);
    }
    _tags = tags;
    _errorMessage = null;
    notifyListeners();
  }

  Future<List<KanbanTask>> _loadTasks(String board, String? taskId) async {
    if (taskId == null) return _repository.getTasks(board);
    final task = await _repository.getTask(board, taskId);
    return [?task];
  }

  Future<void> refresh({
    bool showLoading = true,
    String? taskId,
    bool catalogsOnly = false,
  }) async {
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
      await _reload(taskId: taskId, catalogsOnly: catalogsOnly);
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

  Future<void> retry() => initialize(_boardId, _focusedTaskId);

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
    bool reloadAfterSave = true,
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
      if (reloadAfterSave) await _reload();
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
    bool? deadlineHasTime,
    List<String> tagIds = const [],
    List<String> checklist = const [],
    String? milestoneId,
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
      milestoneId: milestoneId,
      title: title.trim(),
      description: description.trim(),
      status: status,
      priority: priority,
      deadline: deadline,
      deadlineHasTime: deadlineHasTime,
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
    bool? deadlineHasTime,
    List<String>? tagIds,
    String? milestoneId,
    bool clearMilestone = false,
  }) async {
    if (_disposed || _isSaving) return false;
    if (title.trim().isEmpty) {
      _titleError = 'Task title is required';
      notifyListeners();
      return false;
    }
    _titleError = null;
    final edit = task.copyWith(
      title: title.trim(),
      milestoneId: milestoneId,
      clearMilestone: clearMilestone,
      description: description.trim(),
      status: status,
      priority: priority,
      deadline: deadline,
      deadlineHasTime: deadlineHasTime,
      clearDeadline: deadline == null,
    );
    final tags = tagIds?.toSet().toList();
    tags?.sort();
    final pending = _pendingEdit;
    final requestId =
        pending != null &&
            pending.task == edit &&
            listEquals(pending.tags, tags)
        ? pending.id
        : createOperationId();
    _pendingEdit = (task: edit, tags: tags, id: requestId);
    return _save(
      () async {
        final saved = await _repository.saveTaskEdit(
          edit,
          requestId: requestId,
          tagIds: tags,
        );
        _pendingEdit = null;
        if (_disposed) return;
        _tasks = [
          for (final item in _tasks) item.id == saved.id ? saved : item,
        ];
      },
      'Task updated successfully',
      reloadAfterSave: false,
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
    milestoneId: task.milestoneId,
    description: task.description,
    status: task.status,
    priority: task.priority,
    deadline: task.deadline,
    deadlineHasTime: task.deadlineHasTime,
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

  String? _progressRequestId, _progressTaskId, _progressText;
  Future<bool> addProgressUpdate(String taskId, String text) async {
    if (_disposed || _isSaving) return false;
    final validation = TaskActivity.validateProgressText(text);
    final task = _tasks.where((task) => task.id == taskId).firstOrNull;
    if (validation != null ||
        task == null ||
        task.isArchived ||
        isBoardArchived) {
      _errorMessage = validation ?? AppErrorMessages.saveProgressUpdateFailed;
      notifyListeners();
      return false;
    }
    final normalized = text.trim();
    if (_progressTaskId != taskId || _progressText != normalized) {
      _progressRequestId = createOperationId();
      _progressTaskId = taskId;
      _progressText = normalized;
    }
    final saved = await _save(
      () => _repository.addProgressUpdate(
        taskId,
        normalized,
        requestId: _progressRequestId!,
      ),
      'Progress update saved',
      failureMessage: AppErrorMessages.saveProgressUpdateFailed,
    );
    if (saved) _progressRequestId = _progressTaskId = _progressText = null;
    return saved;
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
