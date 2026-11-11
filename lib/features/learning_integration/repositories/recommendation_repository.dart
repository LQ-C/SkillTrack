import '../models/resource_recommendation.dart';

enum RecommendationRequestMode { automatic, manual }

abstract class RecommendationRepository {
  String? get currentUserId;
  Stream<String?> get userChanges;
  Future<List<ResourceRecommendation>> recommendationsForTask(
    String taskId, {
    RecommendationRequestMode mode = RecommendationRequestMode.automatic,
  });
}
