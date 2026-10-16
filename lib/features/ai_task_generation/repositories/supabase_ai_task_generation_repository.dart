import '../models/generated_task_draft.dart';
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
  }) async => GeneratedTaskDraft.parseTasks(
    await _service.generateRaw(
      title: title,
      description: description,
      endDate: endDate,
    ),
    startDate: startDate,
    endDate: endDate,
  );
}
