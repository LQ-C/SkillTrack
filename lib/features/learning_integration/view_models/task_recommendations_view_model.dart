import 'dart:async';
import 'package:flutter/foundation.dart';
import '../../../core/errors/app_exception.dart';
import '../../kanban/models/kanban_status.dart';
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
  bool _sessionEnded = false;
  bool _projectActive;
  List<ResourceRecommendation> _items = const [];
  List<ResourceRecommendation> get items => _items;
  bool _eligible = false;
  bool get eligible => _eligible;
  bool _stalled = false;
  bool _loading = false;
  bool get isLoading => _loading;
  String? _error;
  String? get errorMessage => _error;
  RecommendationRequestMode? _mode;
  bool get hasRequested => _mode != null;
  (String, String, KanbanStatus, DateTime?)? _source;
  int _version = 0;
  bool _disposed = false;

  void setProjectActive(bool active) {
    _projectActive = active;
    _syncTask();
  }

  void _clear() {
    _version++;
    _items = const [];
    _error = null;
    _loading = false;
    _mode = null;
  }

  void _syncTask() {
    if (_disposed) return;
    final task = _tasks.allTasks.where((task) => task.id == taskId).firstOrNull;
    final eligible =
        !_sessionEnded &&
        _owner != null &&
        _repository.currentUserId == _owner &&
        _projectActive &&
        !_tasks.isBoardArchived &&
        task != null &&
        !task.isArchived &&
        !task.isCompleted;
    final source = eligible
        ? (task.title, task.description, task.status, task.updatedAt)
        : null;
    final stalled = eligible && task.isStalled;
    if (_eligible == eligible && _source == source && _stalled == stalled) {
      return;
    }
    // Any changed saved task invalidates in-flight results. Resume also clears
    // automatic results even when a backend leaves updated_at unchanged.
    if (_eligible != eligible ||
        _source != source ||
        (_stalled &&
            !stalled &&
            _mode == RecommendationRequestMode.automatic)) {
      _clear();
    }
    _eligible = eligible;
    _source = source;
    _stalled = stalled;
    if (eligible && stalled && !hasRequested) {
      unawaited(_request(RecommendationRequestMode.automatic));
    } else {
      notifyListeners();
    }
  }

  Future<void> getRecommendations() =>
      _request(RecommendationRequestMode.manual);
  Future<void> retry() => _request(_mode ?? RecommendationRequestMode.manual);

  Future<void> _request(RecommendationRequestMode mode) async {
    if (_disposed ||
        !_eligible ||
        _loading ||
        _repository.currentUserId != _owner ||
        _sessionEnded) {
      return;
    }
    final version = ++_version;
    _mode = mode;
    _loading = true;
    _items = const [];
    _error = null;
    notifyListeners();
    try {
      final items = await _repository.recommendationsForTask(
        taskId,
        mode: mode,
      );
      if (_disposed ||
          version != _version ||
          _repository.currentUserId != _owner) {
        return;
      }
      _items = List.unmodifiable(items);
    } catch (error) {
      if (_disposed ||
          version != _version ||
          _repository.currentUserId != _owner) {
        return;
      }
      _error = AppException.messageFor(
        error,
        fallback: AppErrorMessages.loadRecommendationsFailed,
      );
    } finally {
      if (!_disposed && version == _version) {
        if (_repository.currentUserId != _owner) {
          _sessionEnded = true;
          _syncTask();
        } else {
          _loading = false;
          notifyListeners();
        }
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
