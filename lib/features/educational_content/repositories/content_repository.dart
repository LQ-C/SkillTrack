import 'dart:typed_data';

import 'package:skilltrack/features/educational_content/models/learning_resource.dart';

abstract class ContentRepository {
  String get userId;
  Future<({bool mentor, bool publisher})> permissions();
  Future<List<LearningResource>> list({
    required bool mine,
    required String search,
    String? category,
    String? level,
    String? kind,
    required int offset,
  });
  Future<LearningResource> get(String id);
  Future<Set<String>> bookmarks();
  Future<void> bookmark(String id, bool save);
  Future<void> save(Map<String, dynamic> values, {String? id});
  Future<void> delete(String id);
  Future<void> report(String id, String reason, String details);
}

abstract interface class ResourceFileRepository {
  Future<void> saveResourceFile(
    Map<String, dynamic> values,
    String name,
    Uint8List bytes, {
    String? id,
  });
  Future<String> resourceFileUrl(String path);
}

abstract interface class ResourceOpeningRepository {
  /// Classifies only validated uploaded references; does not fetch any media.
  bool isImageFile(LearningResource resource);
  Future<String> primaryFileUrl(LearningResource resource);
}

/// Metadata only: returned models have no body, media URL or attachment path.
abstract interface class MentorResourcePreviewRepository {
  Future<List<LearningResource>> mentorPreviews(
    String mentorId, {
    required int offset,
  });
}

/// Session identity changes invalidate installation-local Library metadata.
abstract interface class ContentSessionSource {
  Stream<String?> get userChanges;
}
