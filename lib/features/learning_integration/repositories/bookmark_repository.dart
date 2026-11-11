import '../models/resource_recommendation.dart';

abstract class BookmarkRepository {
  String? get currentUserId;
  Stream<String?> get userChanges;
  Future<List<ResourceRecommendation>> savedResources(String taskId);
  Future<void> setBookmark(String taskId, String resourceId, bool saved);
}
