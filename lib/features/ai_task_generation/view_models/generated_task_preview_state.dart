import 'package:flutter/foundation.dart';

import '../models/generated_task_draft.dart';
import '../models/task_generation_request.dart';

abstract interface class GeneratedTaskPreviewState implements Listenable {
  TaskGenerationMode get generationMode;
  List<GeneratedTaskDraft> get pendingGeneratedTasks;
  bool get isConfirmingGeneratedTasks;
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
