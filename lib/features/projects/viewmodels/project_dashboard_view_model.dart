import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../../../core/errors/app_exception.dart';
import '../models/project_with_progress.dart';
import '../repositories/project_repository.dart';

class ProjectDashboardViewModel extends ChangeNotifier {
  ProjectDashboardViewModel(this._repository);
  final ProjectRepository _repository;
  bool _disposed = false;
  List<ProjectWithProgress> _projects = [];
  bool _isLoading = false;
  bool _isMutating = false;
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
      UnmodifiableListView(_projects);
  int get totalCount => _projects.length;
  int get activeCount =>
      _projects.where((item) => item.project.status == 'active').length;
  int get completedCount =>
      _projects.where((item) => item.project.status == 'completed').length;
  List<ProjectWithProgress> get visibleProjects => _projects.where((item) {
    final matchesStatus = _status == 'current'
        ? item.project.status != 'archived'
        : _status == 'all' || item.project.status == _status;
    return matchesStatus && item.project.name.toLowerCase().contains(_search);
  }).toList();

  Future<void> load() async {
    if (_disposed || _isLoading) return;
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();
    try {
      final loaded = await _repository.getProjectsWithProgress();
      if (_disposed) return;
      _projects = loaded;
    } catch (error) {
      if (!_disposed) _errorMessage = AppException.messageFor(error);
    } finally {
      _isLoading = false;
      notifyListeners();
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
    notifyListeners();
    try {
      await operation();
      if (_disposed) return false;
      await load();
      return !_disposed;
    } catch (error) {
      if (!_disposed) _errorMessage = AppException.messageFor(error);
      return false;
    } finally {
      _isMutating = false;
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

  Future<String?> boardFor(String projectId) =>
      _repository.getProjectBoard(projectId);

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
