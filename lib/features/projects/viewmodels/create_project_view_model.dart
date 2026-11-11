import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../../../core/utils/date_formatter.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/utils/operation_id.dart';
import '../../../core/utils/retryable_write.dart';
import '../../ai_task_generation/models/generated_task_draft.dart';
import '../../ai_task_generation/models/task_generation_request.dart';
import '../../ai_task_generation/view_models/generated_task_preview_state.dart';
import '../models/learning_project.dart';
import '../models/project_with_progress.dart';
import '../repositories/project_repository.dart';
import '../../ai_task_generation/repositories/ai_task_generation_repository.dart';

class CreateProjectViewModel extends ChangeNotifier
    with GeneratedTaskPreviewEditor {
  CreateProjectViewModel(
    this._repository, {
    this.original,
    TaskGenerationRepository? generationRepository,
  }) : _generationRepository = generationRepository,
       _startDate = _dateOnly(original?.startDate),
       _endDate = _dateOnly(original?.endDate);
  final ProjectRepository _repository;
  final TaskGenerationRepository? _generationRepository;
  bool _disposed = false;
  final LearningProject? original;
  bool _isSaving = false;
  bool _isGeneratingTasks = false;
  bool _isConfirmingGeneratedTasks = false;
  bool _isRevisingGeneratedTasks = false;
  ({String user, String id})? _confirmation;
  bool _confirmationUncertain = false;
  final _emptyProjectWrites = RetryableWrite<ProjectWithProgress>();
  List<GeneratedTaskDraft>? _pendingTasks;
  String? _pendingName, _pendingDescription;
  String _pendingConstraints = '';
  DateTime? _startDate, _endDate;
  String? _nameError,
      _descriptionError,
      _startDateError,
      _endDateError,
      _errorMessage;

  @override
  bool get canCustomizeGeneratedTasks =>
      !_disposed &&
      !_isSaving &&
      !_isGeneratingTasks &&
      !hasPendingConfirmation;
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
  bool get hasPendingConfirmation => _confirmationUncertain;
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
      value == null ? null : DateFormatter.dateOnly(value);

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
    final today = DateFormatter.today();
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
    String? constraints,
  }) async {
    if (_disposed ||
        _isSaving ||
        _isGeneratingTasks ||
        _pendingTasks != null ||
        hasPendingConfirmation) {
      return null;
    }
    final projectConstraints = LearningProject.normalizeConstraints(
      constraints ?? original?.constraints,
    );
    if ((projectConstraints?.length ?? 0) >
        AppLimits.maxTaskGenerationConstraintsLength) {
      _errorMessage = AppErrorMessages.invalidGenerationConstraints;
      notifyListeners();
      return null;
    }
    final input = (
      user: _repository.currentUserId,
      name: name.trim(),
      description: description.trim().isEmpty ? null : description.trim(),
      constraints: projectConstraints,
      start: _startDate,
      end: _endDate,
    );
    if (!_emptyProjectWrites.contains(input) &&
        !_validateForm(name, description)) {
      return null;
    }
    _isSaving = true;
    notifyListeners();
    try {
      final text = input.description;
      if (original == null) {
        if (_repository.currentUserId == null) {
          _errorMessage = 'Sign in to create a project.';
          return null;
        }
        final created = await _emptyProjectWrites.run(
          input,
          (id) => _repository.saveNewProject(
            requestId: id,
            name: input.name,
            description: input.description,
            constraints: input.constraints,
            startDate: input.start,
            endDate: input.end,
          ),
        );
        return _disposed ? null : created;
      }
      final updated = await _repository.updateProject(
        original!.copyWith(
          name: name.trim(),
          description: text,
          clearDescription: text == null,
          constraints: projectConstraints,
          clearConstraints: projectConstraints == null,
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

  Future<List<GeneratedTaskDraft>?> generateTaskPreview({
    required String name,
    required String description,
    String constraints = '',
  }) async {
    if (_disposed || _isSaving || _isGeneratingTasks || original != null) {
      return null;
    }
    if (_pendingTasks != null) return pendingGeneratedTasks;
    final trimmedConstraints = constraints.trim();
    if (trimmedConstraints.length >
        AppLimits.maxTaskGenerationConstraintsLength) {
      _errorMessage = AppErrorMessages.invalidGenerationConstraints;
      notifyListeners();
      return null;
    }
    if (!_validateForm(name, description, requireDates: true)) return null;
    if (_repository.currentUserId == null) {
      _errorMessage = 'Sign in to generate tasks.';
      notifyListeners();
      return null;
    }
    if (_generationRepository == null) {
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
        constraints: trimmedConstraints,
        startDate: _startDate!,
        endDate: _endDate!,
      );
      if (_disposed) return null;
      if (generated.isEmpty) {
        _errorMessage = AppErrorMessages.noGeneratedTasks;
        return null;
      }
      _pendingTasks = List.unmodifiable(GeneratedTaskDraft.grouped(generated));
      _pendingName = name.trim();
      _pendingDescription = description.trim();
      _pendingConstraints = trimmedConstraints;
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
    final user = _repository.currentUserId;
    if (user == null ||
        (_confirmation != null && _confirmation!.user != user)) {
      _errorMessage = AppErrorMessages.saveGeneratedTasksFailed;
      notifyListeners();
      return null;
    }
    final attempt = _confirmation ??= (user: user, id: createOperationId());
    _confirmationUncertain = true;
    _isSaving = true;
    _isConfirmingGeneratedTasks = true;
    _errorMessage = null;
    notifyListeners();
    try {
      final project = await _repository.saveNewProject(
        requestId: attempt.id,
        name: _pendingName!,
        description: _pendingDescription,
        constraints: _pendingConstraints,
        startDate: generationStartDate,
        endDate: generationEndDate,
        generatedTasks: _pendingTasks!,
      );
      return _disposed ? null : project;
    } on ProjectWriteRejected catch (error) {
      _confirmationUncertain = false;
      if (!_disposed) _errorMessage = error.message;
      return null;
    } catch (_) {
      if (!_disposed) _errorMessage = AppErrorMessages.saveGeneratedTasksFailed;
      return null;
    } finally {
      _isSaving = false;
      _isConfirmingGeneratedTasks = false;
      notifyListeners();
    }
  }

  @override
  void setGeneratedTaskPreview(
    List<GeneratedTaskDraft> tasks, {
    String? error,
  }) {
    if (hasPendingConfirmation) return;
    _confirmation = null;
    _pendingTasks = List.unmodifiable(GeneratedTaskDraft.grouped(tasks));
    _errorMessage = error;
    notifyListeners();
  }

  @override
  Future<bool> reviseGeneratedTasks(String feedback) async {
    final text = feedback.trim();
    if (_disposed ||
        _isSaving ||
        _isGeneratingTasks ||
        _isRevisingGeneratedTasks ||
        hasPendingConfirmation ||
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
        constraints: _pendingConstraints,
        startDate: generationStartDate,
        endDate: generationEndDate,
        sourceMode: TaskGenerationMode.initial,
        feedback: text,
        currentDraft: _pendingTasks!,
      );
      if (_disposed) return false;
      final checked = GeneratedTaskDraft.grouped(revised);
      final invalid = GeneratedTaskDraft.validationError(
        checked,
        startDate: generationStartDate,
        endDate: generationEndDate,
      );
      if (invalid != null) throw AppException(invalid);
      _confirmation = null;
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
        hasPendingConfirmation) {
      return;
    }
    _confirmation = null;
    _pendingTasks = null;
    _pendingName = null;
    _pendingDescription = null;
    _pendingConstraints = '';
    _errorMessage = null;
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
