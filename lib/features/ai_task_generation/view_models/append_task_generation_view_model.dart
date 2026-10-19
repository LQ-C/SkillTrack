import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../../../core/errors/app_exception.dart';
import '../../../core/utils/operation_id.dart';
import '../../kanban/repositories/kanban_repository.dart';
import '../../projects/repositories/project_repository.dart';
import '../models/generated_task_draft.dart';
import '../models/task_generation_request.dart';
import '../repositories/ai_task_generation_repository.dart';
import 'generated_task_preview_state.dart';

class AppendTaskGenerationViewModel extends ChangeNotifier
    with GeneratedTaskPreviewEditor {
  AppendTaskGenerationViewModel({
    required this.projectId,
    required this.boardId,
    required ProjectRepository projectRepository,
    required KanbanRepository taskRepository,
    required TaskGenerationRepository generationRepository,
  }) : _projects = projectRepository,
       _tasks = taskRepository,
       _generator = generationRepository;

  final String projectId;
  final String boardId;
  final ProjectRepository _projects;
  final KanbanRepository _tasks;
  final TaskGenerationRepository _generator;
  bool _disposed = false;
  bool _isGenerating = false;
  bool _isConfirming = false;
  bool _isRevising = false;
  DateTime? _generationStartDate, _generationEndDate;
  List<ExistingTaskSummary> _existingSummaries = const [];
  List<GeneratedTaskDraft>? _pending;
  List<GeneratedTaskDraft>? _saveDraft;
  String? _saveRequestId;
  String? _errorMessage;
  String? _feedbackMessage;

  @override
  TaskGenerationMode get generationMode => TaskGenerationMode.append;
  @override
  bool get canCustomizeGeneratedTasks =>
      !_disposed && !_isGenerating && _saveDraft == null;
  bool get isGeneratingTasks => _isGenerating;
  @override
  bool get isConfirmingGeneratedTasks => _isConfirming;
  @override
  bool get isRevisingGeneratedTasks => _isRevising;
  @override
  DateTime get generationStartDate => _generationStartDate!;
  @override
  DateTime get generationEndDate => _generationEndDate!;
  @override
  String? get errorMessage => _errorMessage;
  String? get feedbackMessage => _feedbackMessage;
  @override
  List<GeneratedTaskDraft> get pendingGeneratedTasks =>
      UnmodifiableListView(_pending ?? const <GeneratedTaskDraft>[]);

  Future<List<GeneratedTaskDraft>?> generateMoreTasks() async {
    if (_disposed || _isGenerating || _isConfirming) return null;
    if (_pending != null) return pendingGeneratedTasks;
    _isGenerating = true;
    _errorMessage = null;
    _feedbackMessage = null;
    notifyListeners();
    try {
      final project = await _projects.getProject(projectId);
      final activeBoard = await _projects.getProjectBoard(projectId);
      if (_disposed) return null;
      if (project == null ||
          project.status == 'archived' ||
          activeBoard != boardId) {
        _errorMessage = AppErrorMessages.requestFailed;
        return null;
      }
      final description = project.description?.trim() ?? '';
      if (description.isEmpty) {
        _errorMessage = AppErrorMessages.projectDescriptionRequired;
        return null;
      }
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final projectStart = project.startDate;
      final start = projectStart != null && projectStart.isAfter(today)
          ? projectStart
          : today;
      final end = project.endDate ?? start.add(const Duration(days: 7));
      if (end.isBefore(today) || end.isBefore(start)) {
        _errorMessage = AppErrorMessages.expiredProjectDeadline;
        return null;
      }
      final existing = await _tasks.getTaskSummaries(boardId);
      final generated = await _generator.generate(
        title: project.name,
        description: description,
        startDate: start,
        endDate: end,
        mode: TaskGenerationMode.append,
        existingTasks: existing.take(100).toList(),
      );
      if (_disposed) return null;
      final fresh = _withoutDuplicates(generated, existing);
      if (fresh.isEmpty) {
        _errorMessage = AppErrorMessages.noAdditionalTasks;
        return null;
      }
      _pending = List.unmodifiable(fresh);
      _generationStartDate = start;
      _generationEndDate = end;
      _existingSummaries = List.unmodifiable(existing);
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
      if (!_disposed) {
        _isGenerating = false;
        notifyListeners();
      }
    }
  }

  @override
  Future<bool?> confirmGeneratedTasks() async {
    if (_disposed ||
        _isGenerating ||
        _isConfirming ||
        _isRevising ||
        _pending == null ||
        _pending!.isEmpty) {
      return null;
    }
    final validation = GeneratedTaskDraft.validationError(
      _pending!,
      startDate: generationStartDate,
      endDate: generationEndDate,
    );
    if (validation != null) {
      _errorMessage = validation;
      notifyListeners();
      return null;
    }
    _isConfirming = true;
    _errorMessage = null;
    notifyListeners();
    try {
      if (await _projects.getProjectBoard(projectId) != boardId) {
        _errorMessage = AppErrorMessages.requestFailed;
        return null;
      }
      final current = await _tasks.getTaskSummaries(boardId);
      if (_disposed) return null;
      final fresh = _saveDraft ?? _withoutDuplicates(_pending!, current);
      if (fresh.isEmpty) {
        _feedbackMessage = AppErrorMessages.additionalTasksAlreadyExist;
        return true;
      }
      _saveDraft = List.unmodifiable(fresh);
      _saveRequestId ??= createOperationId();
      await _tasks.createGeneratedTasks(
        boardId,
        fresh,
        requestId: _saveRequestId,
      );
      return _disposed ? null : true;
    } catch (_) {
      if (!_disposed) _errorMessage = AppErrorMessages.addGeneratedTasksFailed;
      return null;
    } finally {
      if (!_disposed) {
        _isConfirming = false;
        notifyListeners();
      }
    }
  }

  @override
  Iterable<String> get savedTaskTitles =>
      _existingSummaries.map((task) => task.title);

  @override
  void setGeneratedTaskPreview(
    List<GeneratedTaskDraft> tasks, {
    String? error,
  }) {
    _pending = List.unmodifiable(tasks);
    _errorMessage = error;
    notifyListeners();
  }

  @override
  Future<bool> reviseGeneratedTasks(String feedback) async {
    final text = feedback.trim();
    if (_disposed ||
        _isGenerating ||
        _isConfirming ||
        _isRevising ||
        _saveDraft != null ||
        _pending == null ||
        _pending!.isEmpty) {
      return false;
    }
    if (text.isEmpty || text.length > 1000) {
      _errorMessage = AppErrorMessages.invalidRevisionFeedback;
      notifyListeners();
      return false;
    }
    final validation = GeneratedTaskDraft.validationError(
      _pending!,
      startDate: generationStartDate,
      endDate: generationEndDate,
    );
    if (validation != null) {
      _errorMessage = validation;
      notifyListeners();
      return false;
    }
    _isRevising = true;
    _errorMessage = null;
    notifyListeners();
    try {
      final project = await _projects.getProject(projectId);
      if (project == null ||
          project.status == 'archived' ||
          await _projects.getProjectBoard(projectId) != boardId) {
        throw const AppException(AppErrorMessages.requestFailed);
      }
      final existing = await _tasks.getTaskSummaries(boardId);
      final revised = await _generator.revise(
        title: project.name,
        description: project.description?.trim() ?? '',
        startDate: generationStartDate,
        endDate: generationEndDate,
        sourceMode: TaskGenerationMode.append,
        feedback: text,
        currentDraft: _pending!,
        existingTasks: existing.take(100).toList(),
      );
      if (_disposed) return false;
      final fresh = _withoutDuplicates(revised, existing);
      if (fresh.isEmpty) {
        throw const AppException(AppErrorMessages.noAdditionalTasks);
      }
      final checked = GeneratedTaskDraft.reindex(fresh);
      final invalid = GeneratedTaskDraft.validationError(
        checked,
        startDate: generationStartDate,
        endDate: generationEndDate,
        existingTitles: existing.map((task) => task.title),
      );
      if (invalid != null) throw AppException(invalid);
      _pending = List.unmodifiable(checked);
      _existingSummaries = List.unmodifiable(existing);
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
        _isRevising = false;
        notifyListeners();
      }
    }
  }

  static List<GeneratedTaskDraft> _withoutDuplicates(
    List<GeneratedTaskDraft> drafts,
    List<ExistingTaskSummary> existing,
  ) {
    final titles = existing
        .map((task) => normalizedTaskTitle(task.title))
        .toSet();
    return [
      for (final draft in drafts)
        if (titles.add(normalizedTaskTitle(draft.title))) draft,
    ];
  }

  @override
  void cancelGeneratedTaskPreview() {
    if (_disposed || _isConfirming || _isRevising || _pending == null) return;
    _pending = null;
    _saveDraft = null;
    _saveRequestId = null;
    _errorMessage = null;
    notifyListeners();
  }

  void clearFeedback() {
    if (_feedbackMessage == null) return;
    _feedbackMessage = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
