import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../../../core/errors/app_exception.dart';
import '../../kanban/repositories/kanban_repository.dart';
import '../../ai_task_generation/models/generated_task_draft.dart';
import '../../ai_task_generation/models/task_generation_request.dart';
import '../../ai_task_generation/view_models/generated_task_preview_state.dart';
import '../models/learning_project.dart';
import '../models/project_with_progress.dart';
import '../repositories/project_repository.dart';
import '../../ai_task_generation/repositories/ai_task_generation_repository.dart';

class CreateProjectViewModel extends ChangeNotifier
    implements GeneratedTaskPreviewState {
  CreateProjectViewModel(
    this._repository, {
    this.original,
    TaskGenerationRepository? generationRepository,
    KanbanRepository? taskRepository,
  }) : _generationRepository = generationRepository,
       _taskRepository = taskRepository,
       _startDate = _dateOnly(original?.startDate),
       _endDate = _dateOnly(original?.endDate);
  final ProjectRepository _repository;
  final TaskGenerationRepository? _generationRepository;
  final KanbanRepository? _taskRepository;
  bool _disposed = false;
  final LearningProject? original;
  bool _isSaving = false;
  bool _isGeneratingTasks = false;
  bool _isConfirmingGeneratedTasks = false;
  bool _isRevisingGeneratedTasks = false;
  ProjectWithProgress? _pendingProject;
  List<GeneratedTaskDraft>? _pendingTasks;
  String? _pendingName, _pendingDescription;
  DateTime? _startDate, _endDate;
  String? _nameError,
      _descriptionError,
      _startDateError,
      _endDateError,
      _errorMessage;

  bool get isSaving => _isSaving;
  bool get isGeneratingTasks => _isGeneratingTasks;
  @override
  bool get isConfirmingGeneratedTasks => _isConfirmingGeneratedTasks;
  @override
  bool get isRevisingGeneratedTasks => _isRevisingGeneratedTasks;
  @override
  DateTime get generationStartDate => _startDate!;
  @override
  DateTime get generationEndDate => _endDate!;
  @override
  TaskGenerationMode get generationMode => TaskGenerationMode.initial;
  @override
  List<GeneratedTaskDraft> get pendingGeneratedTasks =>
      UnmodifiableListView(_pendingTasks ?? const <GeneratedTaskDraft>[]);
  ProjectWithProgress? get pendingProject => _pendingProject;
  String? get nameError => _nameError;
  String? get descriptionError => _descriptionError;
  DateTime? get startDate => _startDate;
  DateTime? get endDate => _endDate;
  String? get startDateError => _startDateError;
  String? get endDateError => _endDateError;
  String? get dateError => _startDateError ?? _endDateError;
  @override
  String? get errorMessage => _errorMessage;

  static DateTime? _dateOnly(DateTime? value) =>
      value == null ? null : DateTime(value.year, value.month, value.day);

  void setStartDate(DateTime? value) {
    if (_disposed || _isSaving || _isGeneratingTasks || _pendingTasks != null) {
      return;
    }
    _startDate = _dateOnly(value);
    if (original == null &&
        _startDate != null &&
        _endDate != null &&
        _endDate!.isBefore(_startDate!)) {
      _endDate = _startDate;
    }
    _validateDates();
    notifyListeners();
  }

  void setEndDate(DateTime? value) {
    if (_disposed || _isSaving || _isGeneratingTasks || _pendingTasks != null) {
      return;
    }
    _endDate = _dateOnly(value);
    _validateDates();
    notifyListeners();
  }

  void _validateDates() {
    final today = _dateOnly(DateTime.now())!;
    _startDateError =
        original == null && _startDate != null && _startDate!.isBefore(today)
        ? 'Start date cannot be in the past.'
        : null;
    _endDateError =
        _startDate != null &&
            _endDate != null &&
            _endDate!.isBefore(_startDate!)
        ? 'End date cannot be earlier than the start date.'
        : original == null && _endDate != null && _endDate!.isBefore(today)
        ? 'End date cannot be in the past.'
        : null;
  }

  Future<ProjectWithProgress?> submit({
    required String name,
    required String description,
    String status = 'active',
  }) async {
    if (_disposed ||
        _isSaving ||
        _isGeneratingTasks ||
        _pendingTasks != null ||
        _pendingProject != null) {
      return null;
    }
    if (!_validateForm(name, description)) return null;
    _isSaving = true;
    notifyListeners();
    try {
      final text = description.trim().isEmpty ? null : description.trim();
      if (original == null) {
        if (_repository.currentUserId == null) {
          _errorMessage = 'Sign in to create a project.';
          return null;
        }
        final created = await _createProject(name.trim(), text);
        return _disposed ? null : created;
      }
      final updated = await _repository.updateProject(
        original!.copyWith(
          name: name.trim(),
          description: text,
          clearDescription: text == null,
          startDate: _startDate,
          clearStartDate: _startDate == null,
          endDate: _endDate,
          clearEndDate: _endDate == null,
          status: status,
        ),
      );
      if (_disposed) return null;
      final boardId = await _repository.getProjectBoard(updated.id);
      if (_disposed) return null;
      return ProjectWithProgress(
        project: updated,
        boardId: boardId,
        totalTaskCount: 0,
        completedTaskCount: 0,
      );
    } catch (_) {
      if (_disposed) return null;
      _errorMessage = original == null
          ? AppErrorMessages.createProjectFailed
          : AppErrorMessages.updateProjectFailed;
      return null;
    } finally {
      _isSaving = false;
      notifyListeners();
    }
  }

  bool _validateForm(
    String name,
    String description, {
    bool requireDates = false,
  }) {
    _nameError = name.trim().isEmpty ? 'Project name is required.' : null;
    _descriptionError = requireDates && description.trim().isEmpty
        ? 'Add a description to generate tasks.'
        : requireDates && description.trim().length > 4000
        ? 'Description must be 4000 characters or fewer.'
        : null;
    _validateDates();
    _errorMessage = null;
    if (name.trim().length > 150) {
      _nameError = 'Project name must be 150 characters or fewer.';
    }
    if (requireDates && dateError == null) {
      _startDateError ??= _startDate == null
          ? 'Select a start date to generate tasks.'
          : null;
      _endDateError ??= _endDate == null
          ? 'Select an end date to generate tasks.'
          : null;
    }
    notifyListeners();
    return _nameError == null && _descriptionError == null && dateError == null;
  }

  Future<ProjectWithProgress> _createProject(
    String name,
    String? description,
  ) => _repository.createProject(
    name: name,
    description: description,
    startDate: _startDate,
    endDate: _endDate,
  );

  Future<List<GeneratedTaskDraft>?> generateTaskPreview({
    required String name,
    required String description,
  }) async {
    if (_disposed || _isSaving || _isGeneratingTasks || original != null) {
      return null;
    }
    if (_pendingTasks != null) return pendingGeneratedTasks;
    if (!_validateForm(name, description, requireDates: true)) return null;
    if (_repository.currentUserId == null) {
      _errorMessage = 'Sign in to generate tasks.';
      notifyListeners();
      return null;
    }
    if (_generationRepository == null || _taskRepository == null) {
      _errorMessage = AppErrorMessages.generateTasksFailed;
      notifyListeners();
      return null;
    }
    _isGeneratingTasks = true;
    _errorMessage = null;
    notifyListeners();
    try {
      final generated = await _generationRepository.generate(
        title: name.trim(),
        description: description.trim(),
        startDate: _startDate!,
        endDate: _endDate!,
      );
      if (_disposed) return null;
      if (generated.isEmpty) {
        _errorMessage = AppErrorMessages.noGeneratedTasks;
        return null;
      }
      _pendingTasks = List.unmodifiable(generated);
      _pendingName = name.trim();
      _pendingDescription = description.trim();
      return pendingGeneratedTasks;
    } catch (error) {
      if (!_disposed) {
        _errorMessage = AppException.messageFor(
          error,
          fallback: AppErrorMessages.generateTasksFailed,
        );
      }
      return null;
    } finally {
      _isGeneratingTasks = false;
      notifyListeners();
    }
  }

  @override
  Future<ProjectWithProgress?> confirmGeneratedTasks() async {
    if (_disposed ||
        _isSaving ||
        _isGeneratingTasks ||
        _isRevisingGeneratedTasks ||
        _pendingTasks == null ||
        _pendingTasks!.isEmpty) {
      return null;
    }
    final validation = GeneratedTaskDraft.validationError(
      _pendingTasks!,
      startDate: generationStartDate,
      endDate: generationEndDate,
    );
    if (validation != null) {
      _errorMessage = validation;
      notifyListeners();
      return null;
    }
    _isSaving = true;
    _isConfirmingGeneratedTasks = true;
    _errorMessage = null;
    notifyListeners();
    try {
      if (_pendingProject == null) {
        try {
          final description = _pendingDescription!;
          _pendingProject = await _createProject(
            _pendingName!,
            description.isEmpty ? null : description,
          );
        } catch (_) {
          _errorMessage = AppErrorMessages.createProjectFailed;
          return null;
        }
      }
      final project = _pendingProject!;
      final boardId = project.boardId;
      if (boardId == null || boardId.isEmpty) {
        _errorMessage = AppErrorMessages.saveGeneratedTasksFailed;
        return null;
      }
      try {
        // A previous insert may have committed even if its response was lost.
        if (_pendingProject != null && _insertAttempted) {
          final saved = await _taskRepository!.getTasks(boardId);
          if (saved.length == _pendingTasks!.length &&
              saved.every(
                (task) => _pendingTasks!.any(
                  (draft) =>
                      draft.title == task.title &&
                      (draft.position + 1) * 1000 == task.sortOrder &&
                      draft.checklist.length == task.checklistItems.length &&
                      Iterable.generate(draft.checklist.length).every(
                        (index) =>
                            task.checklistItems[index].title ==
                                draft.checklist[index] &&
                            task.checklistItems[index].position == index,
                      ),
                ),
              )) {
            return _disposed ? null : project;
          }
          if (saved.isNotEmpty) {
            _errorMessage = AppErrorMessages.saveGeneratedTasksFailed;
            return null;
          }
        }
        _insertAttempted = true;
        await _taskRepository!.createGeneratedTasks(boardId, _pendingTasks!);
        return _disposed ? null : project;
      } catch (_) {
        _errorMessage = AppErrorMessages.saveGeneratedTasksFailed;
        return null;
      }
    } finally {
      _isSaving = false;
      _isConfirmingGeneratedTasks = false;
      notifyListeners();
    }
  }

  @override
  bool updateGeneratedTask(int index, GeneratedTaskDraft task) {
    if (_disposed ||
        _isSaving ||
        _isRevisingGeneratedTasks ||
        _pendingProject != null ||
        _pendingTasks == null ||
        index < 0 ||
        index >= _pendingTasks!.length) {
      return false;
    }
    final updated = [..._pendingTasks!]
      ..[index] = task.copyWith(position: index);
    final validation = GeneratedTaskDraft.validationError(
      [updated[index]],
      startDate: generationStartDate,
      endDate: generationEndDate,
      existingTitles: [
        for (var other = 0; other < updated.length; other++)
          if (other != index) updated[other].title,
      ],
    );
    if (validation != null) {
      _errorMessage = validation;
      notifyListeners();
      return false;
    }
    _pendingTasks = List.unmodifiable(updated);
    _errorMessage = null;
    notifyListeners();
    return true;
  }

  @override
  void removeGeneratedTask(int index) {
    if (_disposed ||
        _isSaving ||
        _isRevisingGeneratedTasks ||
        _pendingProject != null ||
        _pendingTasks == null ||
        index < 0 ||
        index >= _pendingTasks!.length) {
      return;
    }
    final updated = [..._pendingTasks!]..removeAt(index);
    _pendingTasks = List.unmodifiable(GeneratedTaskDraft.reindex(updated));
    _errorMessage = null;
    notifyListeners();
  }

  @override
  void reorderGeneratedTask(int oldIndex, int newIndex) {
    if (_disposed ||
        _isSaving ||
        _isRevisingGeneratedTasks ||
        _pendingProject != null ||
        _pendingTasks == null ||
        oldIndex < 0 ||
        oldIndex >= _pendingTasks!.length ||
        newIndex < 0 ||
        newIndex > _pendingTasks!.length) {
      return;
    }
    final updated = [..._pendingTasks!];
    final task = updated.removeAt(oldIndex);
    updated.insert(newIndex > oldIndex ? newIndex - 1 : newIndex, task);
    _pendingTasks = List.unmodifiable(GeneratedTaskDraft.reindex(updated));
    notifyListeners();
  }

  @override
  Future<bool> reviseGeneratedTasks(String feedback) async {
    final text = feedback.trim();
    if (_disposed ||
        _isSaving ||
        _isGeneratingTasks ||
        _isRevisingGeneratedTasks ||
        _pendingProject != null ||
        _pendingTasks == null ||
        _pendingTasks!.isEmpty ||
        _generationRepository == null) {
      return false;
    }
    if (text.isEmpty || text.length > 1000) {
      _errorMessage = AppErrorMessages.invalidRevisionFeedback;
      notifyListeners();
      return false;
    }
    final validation = GeneratedTaskDraft.validationError(
      _pendingTasks!,
      startDate: generationStartDate,
      endDate: generationEndDate,
    );
    if (validation != null) {
      _errorMessage = validation;
      notifyListeners();
      return false;
    }
    _isRevisingGeneratedTasks = true;
    _errorMessage = null;
    notifyListeners();
    try {
      final revised = await _generationRepository.revise(
        title: _pendingName!,
        description: _pendingDescription!,
        startDate: generationStartDate,
        endDate: generationEndDate,
        sourceMode: TaskGenerationMode.initial,
        feedback: text,
        currentDraft: _pendingTasks!,
      );
      if (_disposed) return false;
      final checked = GeneratedTaskDraft.reindex(revised);
      final invalid = GeneratedTaskDraft.validationError(
        checked,
        startDate: generationStartDate,
        endDate: generationEndDate,
      );
      if (invalid != null) throw AppException(invalid);
      _pendingTasks = List.unmodifiable(checked);
      return true;
    } catch (error) {
      if (!_disposed) {
        _errorMessage = AppException.messageFor(
          error,
          fallback: AppErrorMessages.generateTasksFailed,
        );
      }
      return false;
    } finally {
      if (!_disposed) {
        _isRevisingGeneratedTasks = false;
        notifyListeners();
      }
    }
  }

  @override
  void cancelGeneratedTaskPreview() {
    if (_disposed ||
        _isSaving ||
        _isRevisingGeneratedTasks ||
        _pendingTasks == null ||
        _pendingProject != null) {
      return;
    }
    _pendingTasks = null;
    _pendingName = null;
    _pendingDescription = null;
    _errorMessage = null;
    notifyListeners();
  }

  bool _insertAttempted = false;

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
