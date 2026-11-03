import '../../../core/constants/app_constants.dart';
import '../../../core/errors/app_exception.dart';

class ProjectMilestone {
  static String? validateTitle(String value) {
    final title = value.trim();
    if (title.isEmpty) return AppErrorMessages.milestoneNameRequired;
    if (title.runes.length > AppLimits.maxMilestoneTitleLength) {
      return AppErrorMessages.milestoneNameTooLong;
    }
    return null;
  }

  const ProjectMilestone({
    required this.id,
    required this.projectId,
    required this.title,
    required this.position,
    this.createdAt,
  });
  final String id, projectId, title;
  final int position;
  final DateTime? createdAt;

  factory ProjectMilestone.fromMap(Map<String, dynamic> row) =>
      ProjectMilestone(
        id: row['id'] as String,
        projectId: row['project_id'] as String,
        title: row['title'] as String,
        position: (row['position'] as num).toInt(),
        createdAt: DateTime.tryParse(
          row['created_at']?.toString() ?? '',
        )?.toUtc(),
      );
  Map<String, Object?> toGenerationJson() => {
    'id': id,
    'title': title,
    'position': position,
  };
}
