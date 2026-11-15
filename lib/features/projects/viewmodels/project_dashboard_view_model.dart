import 'dart:async';
import '../../../core/utils/debug_timing.dart';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../../../core/errors/app_exception.dart';
import '../models/project_with_progress.dart';
import '../repositories/project_repository.dart';

class ProjectDashboardViewModel extends ChangeNotifier {
  ProjectDashboardViewModel(
    this._repository, {
    this.requestTimeout = const Duration(seconds: 20),
  }) {
    _owner = _repository.currentUserId;
    if (_repository is ProjectSessionSource) {
      _session = (_repository as ProjectSessionSource).userChanges.listen((
        user,
      ) {
        if (user == _owner) return;
        _resetUser(user);
        notifyListeners();
      });
    }
  }
  final Duration requestTimeout;
  StreamSubscription<String?>? _session;
  String? _owner;
  int _listVersion = 0, _progressVersion = 0;
  Future<void>? _listPending, _progressPending;
  final _knownProgress = <String>{};
  bool _hasLoaded = false, _progressLoading = false;
  String? progressError;
  bool get hasLoaded => _hasLoaded;
  bool get isProgressLoading => _progressLoading;
  bool get _sameUser => _repository.currentUserId == _owner;
  bool hasProgress(String id) => _sameUser && _knownProgress.contains(id);
  void _resetUser(String? user) {
    _owner = user;
    _listVersion++;
    _progressVersion++;
    _listPending = null;
    _progressPending = null;
    _mutationVersion++;
    _isMutating = false;
    _projects = [];
    _knownProgress.clear();
    _hasLoaded = false;
    _isLoading = false;
    _progressLoading = false;
    _errorMessage = null;
    progressError = null;
  }

  final ProjectRepository _repository;
  bool _disposed = false;
  List<ProjectWithProgress> _projects = [];
  bool _isLoading = false;
  bool _isMutating = false;
  int _mutationVersion = 0;
  bool _isSigningIn = false;
  bool get isMutating => _isMutating;
  bool get isSigningIn => _isSigningIn;
  String? _errorMessage;
  String _search = '';
  String _status = 'current';

  bool get isLoading => _isLoading;
  bool get isSignedIn => _repository.currentUserId != null;
  String? get errorMessage => _errorMessage;
  String get statusFilter => _status;
  UnmodifiableListView<ProjectWithProgress> get projects =>
      UnmodifiableListView(_sameUser ? _projects : []);
  int get totalCount => projects.length;
  int get activeCount =>
      projects.where((item) => item.project.status == 'active').length;
  int get completedCount =>
      projects.where((item) => item.project.status == 'completed').length;
  List<ProjectWithProgress> get visibleProjects => projects.where((item) {
    final matchesStatus = _status == 'current'
        ? item.project.status != 'archived'
        : _status == 'all' || item.project.status == _status;
    return matchesStatus && item.project.name.toLowerCase().contains(_search);
  }).toList();

  Future<void> load() {
    if (_disposed) return Future.value();
    if (!_sameUser) _resetUser(_repository.currentUserId);
    if (_listPending != null) return _listPending!;
    late final Future<void> request;
    request = _load().whenComplete(() {
      if (identical(_listPending, request)) _listPending = null;
    });
    return _listPending = request;
  }

  Future<void> _load() async {
    final version = ++_listVersion;
    final user = _owner;
    bool valid() =>
        !_disposed &&
        version == _listVersion &&
        user == _repository.currentUserId;
    _progressVersion++;
    _progressPending = null;
    _progressLoading = false;
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();
    try {
      final rows = await debugTimed(
        'My Projects list',
        _repository.getUserProjects,
      ).timeout(requestTimeout);
      if (!valid()) return;
      final old = {for (final item in _projects) item.project.id: item};
      _projects = rows
          .where((p) => p.ownerId == user)
          .map(
            (p) =>
                old[p.id]?.copyWith(project: p) ??
                ProjectWithProgress(
                  project: p,
                  boardId: null,
                  totalTaskCount: 0,
                  completedTaskCount: 0,
                ),
          )
          .toList();
      _knownProgress.retainAll(_projects.map((p) => p.project.id));
      _hasLoaded = true;
      _isLoading = false;
      notifyListeners();
      await retryProgress();
    } catch (error) {
      if (valid()) {
        _errorMessage = error is TimeoutException
            ? 'Loading projects timed out. Please retry.'
            : AppException.messageFor(error);
      }
    } finally {
      if (valid()) {
        _isLoading = false;
        notifyListeners();
      }
    }
  }

  Future<void> retryProgress() {
    if (_disposed || !_sameUser || !_hasLoaded) return Future.value();
    if (_progressPending != null) return _progressPending!;
    late final Future<void> request;
    request = _loadProgress().whenComplete(() {
      if (identical(_progressPending, request)) _progressPending = null;
    });
    return _progressPending = request;
  }

  Future<void> _loadProgress() async {
    final version = ++_progressVersion;
    final user = _owner;
    bool valid() =>
        !_disposed &&
        version == _progressVersion &&
        user == _repository.currentUserId;
    if (_projects.isEmpty) {
      progressError = null;
      return;
    }
    _progressLoading = true;
    progressError = null;
    notifyListeners();
    try {
      final rows = await debugTimed(
        'My Projects progress',
        () => _repository is ProjectProgressSource
            ? (_repository as ProjectProgressSource).progressForProjects(
                _projects.map((i) => i.project).toList(),
              )
            : _repository.getProjectsWithProgress(),
      ).timeout(requestTimeout);
      if (!valid()) return;
      final byId = {
        for (final row in rows)
          if (row.project.ownerId == user) row.project.id: row,
      };
      _projects = [
        for (final item in _projects)
          byId[item.project.id]?.copyWith(project: item.project) ?? item,
      ];
      _knownProgress.addAll(byId.keys);
    } catch (error) {
      if (valid()) {
        progressError = error is TimeoutException
            ? 'Progress timed out. Your projects are still available.'
            : 'Could not load project progress.';
      }
    } finally {
      if (valid()) {
        _progressLoading = false;
        notifyListeners();
      }
    }
  }

  Future<bool> signIn(String email, String password) async {
    if (_disposed || _isSigningIn) return false;
    if (email.trim().isEmpty || password.isEmpty) {
      _errorMessage = AppErrorMessages.credentialsRequired;
      notifyListeners();
      return false;
    }
    _isSigningIn = true;
    notifyListeners();
    try {
      await _repository.signIn(email.trim(), password);
      if (_disposed) return false;
      await load();
      return !_disposed && _errorMessage == null;
    } catch (error) {
      if (!_disposed) _errorMessage = AppException.messageFor(error);
      return false;
    } finally {
      _isSigningIn = false;
      notifyListeners();
    }
  }

  void search(String value) {
    final query = value.trim().toLowerCase();
    if (_disposed || query == _search) return;
    _search = query;
    notifyListeners();
  }

  void filter(String status) {
    _status = status;
    notifyListeners();
  }

  Future<bool> _mutate(Future<void> Function() operation) async {
    if (_disposed || _isMutating) return false;
    _isMutating = true;
    final user = _repository.currentUserId;
    final mutationVersion = ++_mutationVersion;
    notifyListeners();
    try {
      await operation();
      if (_disposed || user != _repository.currentUserId) return false;
      // The write has completed; progress hydration must not lock project navigation.
      _isMutating = false;
      _listVersion++;
      _listPending = null;
      await load();
      return !_disposed;
    } catch (error) {
      if (!_disposed) _errorMessage = AppException.messageFor(error);
      return false;
    } finally {
      if (mutationVersion == _mutationVersion) _isMutating = false;
      notifyListeners();
    }
  }

  Future<bool> markCompleted(ProjectWithProgress item) => _mutate(() async {
    await _repository.updateProject(item.project.copyWith(status: 'completed'));
  });
  Future<bool> archive(String id) =>
      _mutate(() => _repository.archiveProject(id));
  Future<bool> delete(String id) =>
      _mutate(() => _repository.deleteProject(id));

  Future<String?> boardFor(String projectId) async {
    final user = _repository.currentUserId;
    final board = await _repository
        .getProjectBoard(projectId)
        .timeout(requestTimeout);
    if (_disposed || user != _repository.currentUserId) return null;
    return board;
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _session?.cancel();
    _listVersion++;
    _progressVersion++;
    super.dispose();
  }
}
