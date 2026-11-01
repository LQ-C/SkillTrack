class ProjectMilestone {
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
