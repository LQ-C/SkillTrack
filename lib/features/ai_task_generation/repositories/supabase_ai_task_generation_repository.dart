import '../../projects/models/project_milestone.dart';
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
    String constraints = '',
    String feedback = '',
    String? projectId,
    List<ProjectMilestone> existingMilestones = const [],
  }) async => GeneratedTaskDraft.parseTasks(
    await _service.generateRaw(
      title: title,
      description: description,
      endDate: endDate,
      mode: mode,
      feedback: feedback,
      existingTasks: existingTasks,
      constraints: constraints,
      projectId: projectId,
      existingMilestones: existingMilestones,
    ),
    startDate: startDate,
    endDate: endDate,
    minimumTaskCount: mode == TaskGenerationMode.append
        ? 0
        : mode == TaskGenerationMode.replace
        ? 1
        : 3,
    existingMilestones: existingMilestones,
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
    String constraints = '',
    String? projectId,
    List<ProjectMilestone> existingMilestones = const [],
  }) async => GeneratedTaskDraft.parseTasks(
    await _service.reviseRaw(
      title: title,
      description: description,
      endDate: endDate,
      sourceMode: sourceMode,
      feedback: feedback,
      currentDraft: currentDraft,
      existingTasks: existingTasks,
      constraints: constraints,
      projectId: projectId,
      existingMilestones: existingMilestones,
    ),
    startDate: startDate,
    endDate: endDate,
    minimumTaskCount: 1,
    previousDraft: currentDraft,
    existingMilestones: existingMilestones,
    preservedDeadlines: {
      for (final task in currentDraft)
        normalizedTaskTitle(task.title): task.deadline,
    },
  );
}
