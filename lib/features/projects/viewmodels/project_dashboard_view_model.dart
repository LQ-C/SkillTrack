import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../models/project_with_progress.dart';
import '../repositories/project_repository.dart';

class ProjectDashboardViewModel extends ChangeNotifier {
  ProjectDashboardViewModel(this._repository);
  final ProjectRepository _repository;
  List<ProjectWithProgress> _projects = [];
  bool _isLoading = false;
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
    return matchesStatus &&
        item.project.name.toLowerCase().contains(_search.toLowerCase().trim());
  }).toList();

  Future<void> load() async {
    if (_isLoading) return;
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();
    try {
      _projects = await _repository.getProjectsWithProgress();
    } catch (error) {
      _errorMessage = error.toString();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<bool> signIn(String email, String password) async {
    if (email.trim().isEmpty || password.isEmpty) {
      _errorMessage = 'Enter your email and password.';
      notifyListeners();
      return false;
    }
    try {
      await _repository.signIn(email.trim(), password);
      await load();
      return _errorMessage == null;
    } catch (error) {
      _errorMessage = error.toString();
      notifyListeners();
      return false;
    }
  }

  void search(String value) {
    _search = value;
    notifyListeners();
  }

  void filter(String status) {
    _status = status;
    notifyListeners();
  }

  Future<bool> markCompleted(ProjectWithProgress item) async {
    try {
      await _repository.updateProject(
        item.project.copyWith(status: 'completed'),
      );
      await load();
      return true;
    } catch (error) {
      _errorMessage = error.toString();
      notifyListeners();
      return false;
    }
  }

  Future<bool> archive(String id) async {
    try {
      await _repository.archiveProject(id);
      await load();
      return true;
    } catch (error) {
      _errorMessage = error.toString();
      notifyListeners();
      return false;
    }
  }

  Future<bool> delete(String id) async {
    try {
      await _repository.deleteProject(id);
      await load();
      return true;
    } catch (error) {
      _errorMessage = error.toString();
      notifyListeners();
      return false;
    }
  }

  Future<String?> boardFor(String projectId) =>
      _repository.getProjectBoard(projectId);
}
