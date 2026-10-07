import 'package:flutter/foundation.dart';

import '../models/learning_project.dart';
import '../models/project_with_progress.dart';
import '../repositories/project_repository.dart';

class CreateProjectViewModel extends ChangeNotifier {
  CreateProjectViewModel(this._repository, {this.original});
  final ProjectRepository _repository;
  final LearningProject? original;
  bool _isSaving = false;
  String? _nameError, _dateError, _errorMessage;

  bool get isSaving => _isSaving;
  String? get nameError => _nameError;
  String? get dateError => _dateError;
  String? get errorMessage => _errorMessage;

  Future<ProjectWithProgress?> submit({
    required String name,
    required String description,
    DateTime? startDate,
    DateTime? endDate,
    String status = 'active',
  }) async {
    if (_isSaving) return null;
    _nameError = name.trim().isEmpty ? 'Project name is required.' : null;
    _dateError =
        startDate != null && endDate != null && endDate.isBefore(startDate)
        ? 'End date cannot be earlier than the start date.'
        : null;
    _errorMessage = null;
    if (_nameError != null || _dateError != null) {
      notifyListeners();
      return null;
    }
    if (name.trim().length > 150) {
      _nameError = 'Project name must be 150 characters or fewer.';
      notifyListeners();
      return null;
    }
    _isSaving = true;
    notifyListeners();
    try {
      final text = description.trim().isEmpty ? null : description.trim();
      if (original == null) {
        if (_repository.currentUserId == null) {
          _errorMessage = 'Sign in to create a project.';
          return null;
        }
        return await _repository.createProject(
          name: name.trim(),
          description: text,
          startDate: startDate,
          endDate: endDate,
        );
      }
      final updated = await _repository.updateProject(
        original!.copyWith(
          name: name.trim(),
          description: text,
          clearDescription: text == null,
          startDate: startDate,
          clearStartDate: startDate == null,
          endDate: endDate,
          clearEndDate: endDate == null,
          status: status,
        ),
      );
      return ProjectWithProgress(
        project: updated,
        boardId: await _repository.getProjectBoard(updated.id),
        totalTaskCount: 0,
        completedTaskCount: 0,
      );
    } catch (_) {
      _errorMessage = original == null
          ? 'Unable to create the project. Please try again.'
          : 'Unable to update the project. Please try again.';
      return null;
    } finally {
      _isSaving = false;
      notifyListeners();
    }
  }
}
