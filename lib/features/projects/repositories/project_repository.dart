import '../models/learning_project.dart';
import '../models/project_milestone.dart';
import '../models/project_with_progress.dart';

abstract class ProjectRepository {
  String? get currentUserId;
  Future<void> signIn(String email, String password);
  Future<List<LearningProject>> getUserProjects();
  Future<List<ProjectMilestone>> getProjectMilestones(String projectId);
  Future<LearningProject?> getProject(String projectId);
  Future<bool> canCreateMilestone({
    required String projectId,
    required String boardId,
  });
  Future<ProjectMilestone> createMilestone({
    required String boardId,
    required String title,
    required String requestId,
  });
  Future<ProjectWithProgress> createProject({
    required String name,
    String? description,
    String? constraints,
    DateTime? startDate,
    DateTime? endDate,
  });
  Future<LearningProject> updateProject(LearningProject project);
  Future<void> archiveProject(String projectId);
  Future<void> deleteProject(String projectId);
  Future<String?> getProjectBoard(String projectId);
  Future<List<ProjectWithProgress>> getProjectsWithProgress();
}
