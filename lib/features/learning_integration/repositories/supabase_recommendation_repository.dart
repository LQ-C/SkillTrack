import 'bookmark_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/errors/app_exception.dart';
import '../models/resource_recommendation.dart';
import 'recommendation_repository.dart';

class SupabaseRecommendationRepository
    implements RecommendationRepository, BookmarkRepository {
  SupabaseRecommendationRepository(this._client);
  final SupabaseClient _client;

  @override
  String? get currentUserId => _client.auth.currentUser?.id;
  @override
  Stream<String?> get userChanges =>
      _client.auth.onAuthStateChange.map((event) => event.session?.user.id);

  @override
  Future<SavedTaskRecommendations> loadRecommendations(String taskId) async {
    final owner = currentUserId;
    try {
      if (owner == null) throw StateError('Signed out');
      final result = await _client.rpc(
        'task_recommendations',
        params: {'p_task_id': taskId},
      );
      if (currentUserId != owner) throw StateError('Session changed');
      return SavedTaskRecommendations.fromMap(
        Map<String, dynamic>.from(result as Map),
      );
    } catch (_) {
      throw const AppException(AppErrorMessages.loadRecommendationsFailed);
    }
  }

  @override
  Future<List<ResourceRecommendation>> recommendationsForTask(
    String taskId, {
    RecommendationRequestMode mode = RecommendationRequestMode.automatic,
  }) async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) {
      throw const AppException(AppErrorMessages.loadRecommendationsFailed);
    }
    try {
      final response = await _client.functions
          .invoke(
            'recommend-resources',
            body: {'task_id': taskId, 'mode': mode.name},
          )
          .timeout(const Duration(seconds: 75));
      if (_client.auth.currentUser?.id != userId) {
        throw const AppException(AppErrorMessages.loadRecommendationsFailed);
      }
      final data = response.data;
      if (response.status != 200 ||
          data is! Map ||
          !['ok', 'empty', 'not_stalled'].contains(data['status']) ||
          data['recommendations'] is! List) {
        throw const FormatException('Invalid recommendation response');
      }
      final items = data['recommendations'] as List;
      if (items.length > 3) {
        throw const FormatException('Too many recommendations');
      }
      return List.unmodifiable(
        items.map(
          (item) => ResourceRecommendation.fromMap(
            Map<String, dynamic>.from(item as Map),
          ),
        ),
      );
    } catch (_) {
      throw const AppException(AppErrorMessages.loadRecommendationsFailed);
    }
  }

  @override
  Future<List<ResourceRecommendation>> savedResources(String taskId) async {
    final owner = currentUserId;
    try {
      if (owner == null) throw StateError('Signed out');
      final rows = await _client.rpc(
        'task_saved_resources',
        params: {'p_task_id': taskId},
      );
      if (currentUserId != owner) throw StateError('Session changed');
      return List.unmodifiable(
        (rows as List).map(
          (row) =>
              ResourceRecommendation.fromMap(Map<String, dynamic>.from(row)),
        ),
      );
    } catch (_) {
      throw const AppException(AppErrorMessages.loadBookmarksFailed);
    }
  }

  @override
  Future<void> setBookmark(String taskId, String resourceId, bool saved) async {
    final owner = currentUserId;
    try {
      if (owner == null) throw StateError('Signed out');
      await _client.rpc(
        'set_task_resource_bookmark',
        params: {
          'p_task_id': taskId,
          'p_resource_id': resourceId,
          'p_saved': saved,
        },
      );
      if (currentUserId != owner) throw StateError('Session changed');
    } catch (_) {
      throw const AppException(AppErrorMessages.saveBookmarkFailed);
    }
  }
}
