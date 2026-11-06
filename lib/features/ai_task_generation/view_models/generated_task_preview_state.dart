import 'package:flutter/foundation.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/errors/app_exception.dart';
import '../models/generated_milestone_draft.dart';
import '../models/generated_task_draft.dart';
import '../models/task_generation_request.dart';

abstract interface class GeneratedTaskPreviewState implements Listenable {
  TaskGenerationMode get generationMode;
  List<GeneratedTaskDraft> get pendingGeneratedTasks;
  List<GeneratedMilestoneDraft> get availableGeneratedMilestones;
  bool renameGeneratedMilestone(String localId, String title);
  bool get isConfirmingGeneratedTasks;
  bool get canCustomizeGeneratedTasks;
  bool get isRevisingGeneratedTasks;
  DateTime get generationStartDate;
  DateTime get generationEndDate;
  String? get errorMessage;
  bool updateGeneratedTask(int index, GeneratedTaskDraft task);
  void removeGeneratedTask(int index);
  void reorderGeneratedTask(int oldIndex, int newIndex);
  Future<bool> reviseGeneratedTasks(String feedback);
  Future<Object?> confirmGeneratedTasks();
  void cancelGeneratedTaskPreview();
}

/// Shared local editing rules for both initial and additional-task previews.
mixin GeneratedTaskPreviewEditor on ChangeNotifier
    implements GeneratedTaskPreviewState {
  Iterable<String> get savedTaskTitles => const [];
  Iterable<GeneratedMilestoneDraft> get existingGeneratedMilestones => const [];

  @override
  List<GeneratedMilestoneDraft> get availableGeneratedMilestones {
    final groups = <String, GeneratedMilestoneDraft>{};
    for (final task in pendingGeneratedTasks) {
      if (task.milestone != null) {
        groups[task.milestone!.localId] = task.milestone!;
      }
    }
    for (final group in existingGeneratedMilestones) {
      groups.putIfAbsent(group.localId, () => group);
    }
    return List.unmodifiable(groups.values);
  }

  @override
  bool renameGeneratedMilestone(String localId, String title) {
    final group = availableGeneratedMilestones
        .where((group) => group.localId == localId)
        .firstOrNull;
    if (!_canEdit || group == null || group.existingMilestoneId != null) {
      return false;
    }
    final name = title.trim();
    if (name.length > AppLimits.maxMilestoneTitleLength) return false;
    setGeneratedTaskPreview([
      for (final task in pendingGeneratedTasks)
        task.milestone?.localId == localId
            ? task.copyWith(milestone: group.copyWith(title: name))
            : task,
    ], error: name.isEmpty ? AppErrorMessages.invalidMilestone : null);
    return name.isNotEmpty;
  }

  @protected
  void setGeneratedTaskPreview(List<GeneratedTaskDraft> tasks, {String? error});

  bool get _canEdit =>
      canCustomizeGeneratedTasks &&
      !isConfirmingGeneratedTasks &&
      !isRevisingGeneratedTasks;

  @override
  bool updateGeneratedTask(int index, GeneratedTaskDraft task) {
    final current = pendingGeneratedTasks;
    if (!_canEdit || index < 0 || index >= current.length) return false;
    if (task.milestone != null &&
        !availableGeneratedMilestones.any(
          (group) => group.localId == task.milestone!.localId,
        )) {
      return false;
    }
    final updated = [...current]..[index] = task.copyWith(position: index);
    final error = GeneratedTaskDraft.validationError(
      updated,
      startDate: generationStartDate,
      endDate: generationEndDate,
      existingTitles: savedTaskTitles,
    );
    setGeneratedTaskPreview(error == null ? updated : current, error: error);
    return error == null;
  }

  @override
  void removeGeneratedTask(int index) {
    final current = pendingGeneratedTasks;
    if (!_canEdit || index < 0 || index >= current.length) return;
    setGeneratedTaskPreview(
      GeneratedTaskDraft.reindex([...current]..removeAt(index)),
    );
  }

  @override
  void reorderGeneratedTask(int oldIndex, int newIndex) {
    final current = pendingGeneratedTasks;
    if (!_canEdit ||
        oldIndex < 0 ||
        oldIndex >= current.length ||
        newIndex < 0 ||
        newIndex > current.length) {
      return;
    }
    final destination = (newIndex > oldIndex ? newIndex - 1 : newIndex).clamp(
      0,
      current.length - 1,
    );
    if (current[oldIndex].milestone?.localId !=
        current[destination].milestone?.localId) {
      setGeneratedTaskPreview(
        current,
        error: AppErrorMessages.milestoneReorder,
      );
      return;
    }
    final updated = [...current];
    final task = updated.removeAt(oldIndex);
    updated.insert(newIndex > oldIndex ? newIndex - 1 : newIndex, task);
    setGeneratedTaskPreview(GeneratedTaskDraft.reindex(updated));
  }
}
