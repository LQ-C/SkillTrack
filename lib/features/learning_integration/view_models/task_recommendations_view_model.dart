import 'dart:async';
import 'package:flutter/foundation.dart';
import '../../../core/errors/app_exception.dart';
import '../../kanban/viewmodels/kanban_view_model.dart';
import '../models/resource_recommendation.dart';
import '../repositories/recommendation_repository.dart';

class TaskRecommendationsViewModel extends ChangeNotifier {
  TaskRecommendationsViewModel(
    this._repository, {
    required this.taskId,
    required KanbanViewModel tasks,
    bool projectActive = true,
  }) : _tasks = tasks,
       _projectActive = projectActive,
       _owner = _repository.currentUserId {
    _tasks.addListener(_syncTask);
    _authSubscription = _repository.userChanges.listen((user) {
      if (user != _owner) _sessionEnded = true;
      _syncTask();
    });
    _syncTask();
  }
  final RecommendationRepository _repository;
  final KanbanViewModel _tasks;
  final String taskId;
  final String? _owner;
  StreamSubscription<String?>? _authSubscription;
  bool _sessionEnded = false, _disposed = false, _projectActive;
  bool _eligible = false,
      _visible = false,
      _loading = false,
      _generated = false,
      _retryLoad = false;
  bool get eligible => _eligible;
  bool get visible => _visible;
  bool get isLoading => _loading;
  bool get hasRequested => _generated;
  List<ResourceRecommendation> _items = const [];
  List<ResourceRecommendation> get items => _items;
  String? _error;
  String? get errorMessage => _error;
  Object? _source;
  int _version = 0;
  Future<void>? _loadFuture;
  RecommendationRequestMode _mode = RecommendationRequestMode.manual;
  bool get _active =>
      !_disposed &&
      !_sessionEnded &&
      _owner != null &&
      _repository.currentUserId == _owner;
  bool _current(int version) => _active && version == _version;

  void setProjectActive(bool active) {
    _projectActive = active;
    _syncTask();
  }

  void _syncTask() {
    if (_disposed) return;
    final task = _tasks.allTasks.where((t) => t.id == taskId).firstOrNull;
    final visible = _active && task != null;
    final eligible =
        visible &&
        _projectActive &&
        !_tasks.isBoardArchived &&
        !task.isArchived &&
        !task.isCompleted;
    final source = visible
        ? (
            task.title,
            task.description,
            task.status,
            task.updatedAt,
            task.isStalled,
            task.stalledAt,
            eligible,
          )
        : null;
    if (_source == source && _visible == visible) return;
    _source = source;
    _visible = visible;
    _eligible = eligible;
    _version++;
    _loading = false;
    _error = null;
    if (!visible) {
      _items = const [];
      _generated = false;
      notifyListeners();
      return;
    }
    // Reload persisted associations on task changes, never blindly rerun matching.
    _loadFuture = _load();
  }

  Future<void> _load() async {
    final version = ++_version;
    _loading = true;
    _retryLoad = true;
    _error = null;
    notifyListeners();
    try {
      final saved = await _repository.loadRecommendations(taskId);
      if (!_current(version)) return;
      _items = saved.items;
      _generated = saved.generated;
      _retryLoad = false;
      _loading = false;
      final task = _tasks.allTasks.where((t) => t.id == taskId).firstOrNull;
      if (_eligible &&
          task != null &&
          task.isStalled &&
          (!saved.generated || task.stalledAt != saved.stalledAt)) {
        await _request(RecommendationRequestMode.automatic);
      }
    } catch (error) {
      if (_current(version)) {
        _error = AppException.messageFor(
          error,
          fallback: AppErrorMessages.loadRecommendationsFailed,
        );
      }
    } finally {
      if (_current(version)) {
        _loading = false;
        notifyListeners();
      }
    }
  }

  Future<void> getRecommendations() async {
    if (_loading && !_retryLoad) return;
    final version = _version;
    if (_loading) await _loadFuture;
    if (!_current(version)) return;
    await _request(RecommendationRequestMode.manual);
  }

  Future<void> retry() async {
    if (_loading || !_active) return;
    if (_retryLoad) {
      _loadFuture = _load();
      await _loadFuture;
    } else {
      await _request(_mode);
    }
  }

  Future<void> _request(RecommendationRequestMode mode) async {
    if (!_active || !_eligible || _loading) return;
    final version = ++_version;
    _mode = mode;
    _loading = true;
    _error = null;
    _retryLoad = false;
    notifyListeners();
    try {
      final items = await _repository.recommendationsForTask(
        taskId,
        mode: mode,
      );
      if (!_current(version)) return;
      _items = List.unmodifiable(items);
      _generated = true;
    } catch (error) {
      if (_current(version)) {
        _error = AppException.messageFor(
          error,
          fallback: AppErrorMessages.loadRecommendationsFailed,
        );
      }
    } finally {
      if (_current(version)) {
        _loading = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _version++;
    _authSubscription?.cancel();
    _tasks.removeListener(_syncTask);
    super.dispose();
  }
}
