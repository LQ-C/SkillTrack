import '../models/learning_project.dart';
import '../models/project_with_progress.dart';

abstract class ProjectRepository {
  String? get currentUserId;
  Future<void> signIn(String email, String password);
  Future<List<LearningProject>> getUserProjects();
  Future<LearningProject?> getProject(String projectId);
  Future<ProjectWithProgress> createProject({
    required String name,
    String? description,
    DateTime? startDate,
    DateTime? endDate,
  });
  Future<LearningProject> updateProject(LearningProject project);
  Future<void> archiveProject(String projectId);
  Future<void> deleteProject(String projectId);
  Future<String?> getProjectBoard(String projectId);
  Future<List<ProjectWithProgress>> getProjectsWithProgress();
}
