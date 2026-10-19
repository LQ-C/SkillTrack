import 'package:flutter/foundation.dart';

import '../models/generated_task_draft.dart';
import '../models/task_generation_request.dart';

abstract interface class GeneratedTaskPreviewState implements Listenable {
  TaskGenerationMode get generationMode;
  List<GeneratedTaskDraft> get pendingGeneratedTasks;
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
    final updated = [...current]..[index] = task.copyWith(position: index);
    final error = GeneratedTaskDraft.validationError(
      [updated[index]],
      startDate: generationStartDate,
      endDate: generationEndDate,
      existingTitles: [
        ...savedTaskTitles,
        for (var other = 0; other < current.length; other++)
          if (other != index) current[other].title,
      ],
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
    final updated = [...current];
    final task = updated.removeAt(oldIndex);
    updated.insert(newIndex > oldIndex ? newIndex - 1 : newIndex, task);
    setGeneratedTaskPreview(GeneratedTaskDraft.reindex(updated));
  }
}
