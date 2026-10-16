import '../models/generated_task_draft.dart';

abstract class TaskGenerationRepository {
  Future<List<GeneratedTaskDraft>> generate({
    required String title,
    required String description,
    required DateTime startDate,
    required DateTime endDate,
  });
}
