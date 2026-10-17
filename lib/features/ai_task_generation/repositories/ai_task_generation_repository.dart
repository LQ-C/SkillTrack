import '../models/generated_task_draft.dart';
import '../models/task_generation_request.dart';

abstract class TaskGenerationRepository {
  Future<List<GeneratedTaskDraft>> generate({
    required String title,
    required String description,
    required DateTime startDate,
    required DateTime endDate,
    TaskGenerationMode mode = TaskGenerationMode.initial,
    List<ExistingTaskSummary> existingTasks = const [],
  });
  Future<List<GeneratedTaskDraft>> revise({
    required String title,
    required String description,
    required DateTime startDate,
    required DateTime endDate,
    required TaskGenerationMode sourceMode,
    required String feedback,
    required List<GeneratedTaskDraft> currentDraft,
    List<ExistingTaskSummary> existingTasks = const [],
  });
}
