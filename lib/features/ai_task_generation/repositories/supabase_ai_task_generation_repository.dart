import '../models/generated_task_draft.dart';
import '../models/task_generation_request.dart';
import '../services/ai_task_generation_service.dart';
import 'ai_task_generation_repository.dart';

class SupabaseTaskGenerationRepository implements TaskGenerationRepository {
  SupabaseTaskGenerationRepository(this._service);
  final AiTaskGenerationService _service;

  @override
  Future<List<GeneratedTaskDraft>> generate({
    required String title,
    required String description,
    required DateTime startDate,
    required DateTime endDate,
    TaskGenerationMode mode = TaskGenerationMode.initial,
    List<ExistingTaskSummary> existingTasks = const [],
  }) async => GeneratedTaskDraft.parseTasks(
    await _service.generateRaw(
      title: title,
      description: description,
      endDate: endDate,
      mode: mode,
      existingTasks: existingTasks,
    ),
    startDate: startDate,
    endDate: endDate,
    minimumTaskCount: mode == TaskGenerationMode.append ? 0 : 3,
  );

  @override
  Future<List<GeneratedTaskDraft>> revise({
    required String title,
    required String description,
    required DateTime startDate,
    required DateTime endDate,
    required TaskGenerationMode sourceMode,
    required String feedback,
    required List<GeneratedTaskDraft> currentDraft,
    List<ExistingTaskSummary> existingTasks = const [],
  }) async => GeneratedTaskDraft.parseTasks(
    await _service.reviseRaw(
      title: title,
      description: description,
      endDate: endDate,
      sourceMode: sourceMode,
      feedback: feedback,
      currentDraft: currentDraft,
      existingTasks: existingTasks,
    ),
    startDate: startDate,
    endDate: endDate,
    minimumTaskCount: 1,
    preservedDeadlines: {
      for (final task in currentDraft)
        normalizedTaskTitle(task.title): task.deadline,
    },
  );
}
