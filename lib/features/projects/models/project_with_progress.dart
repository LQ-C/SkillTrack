import 'learning_project.dart';

class ProjectWithProgress {
  const ProjectWithProgress({
    required this.project,
    required this.boardId,
    required this.totalTaskCount,
    required this.completedTaskCount,
  });

  final LearningProject project;
  final String? boardId;
  final int totalTaskCount;
  final int completedTaskCount;

  double get progress =>
      totalTaskCount == 0 ? 0 : completedTaskCount / totalTaskCount;

  factory ProjectWithProgress.fromMap(Map<String, dynamic> map) =>
      ProjectWithProgress(
        project: LearningProject.fromMap(
          map['project'] as Map<String, dynamic>,
        ),
        boardId: map['board_id']?.toString(),
        totalTaskCount: (map['total_task_count'] as num?)?.toInt() ?? 0,
        completedTaskCount: (map['completed_task_count'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toMap() => {
    'project': project.toMap(),
    'board_id': boardId,
    'total_task_count': totalTaskCount,
    'completed_task_count': completedTaskCount,
  };

  ProjectWithProgress copyWith({
    LearningProject? project,
    String? boardId,
    int? totalTaskCount,
    int? completedTaskCount,
  }) => ProjectWithProgress(
    project: project ?? this.project,
    boardId: boardId ?? this.boardId,
    totalTaskCount: totalTaskCount ?? this.totalTaskCount,
    completedTaskCount: completedTaskCount ?? this.completedTaskCount,
  );
}
