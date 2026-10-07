import 'package:skilltrack/features/projects/models/learning_project.dart';
import 'package:skilltrack/features/projects/models/project_with_progress.dart';
import 'package:skilltrack/features/projects/repositories/project_repository.dart';

class FakeProjectRepository implements ProjectRepository {
  FakeProjectRepository({
    this.userId = 'user-1',
    List<ProjectWithProgress>? items,
  }) : stored = List.of(items ?? []);
  String? userId;
  List<ProjectWithProgress> stored;
  bool failBoardCreation = false;
  bool failLoad = false;
  bool deleteCalled = false;
  int _nextId = 10;

  @override
  String? get currentUserId => userId;

  @override
  Future<void> signIn(String email, String password) async {
    userId = 'user-1';
  }

  @override
  Future<List<LearningProject>> getUserProjects() async =>
      (await getProjectsWithProgress()).map((item) => item.project).toList();

  @override
  Future<LearningProject?> getProject(String projectId) async => stored
      .where(
        (item) =>
            item.project.id == projectId && item.project.ownerId == userId,
      )
      .firstOrNull
      ?.project;

  @override
  Future<ProjectWithProgress> createProject({
    required String name,
    String? description,
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    if (userId == null) throw StateError('not signed in');
    final id = 'project-${_nextId++}';
    final project = LearningProject(
      id: id,
      ownerId: userId!,
      name: name,
      description: description,
      status: 'active',
      startDate: startDate,
      endDate: endDate,
    );
    if (failBoardCreation) throw StateError('board insert failed');
    final item = ProjectWithProgress(
      project: project,
      boardId: 'board-$id',
      totalTaskCount: 0,
      completedTaskCount: 0,
    );
    stored.add(item);
    return item;
  }

  @override
  Future<LearningProject> updateProject(LearningProject project) async {
    stored = stored
        .map(
          (item) => item.project.id == project.id
              ? item.copyWith(project: project)
              : item,
        )
        .toList();
    return project;
  }

  @override
  Future<void> archiveProject(String projectId) async {
    final item = stored.where((item) => item.project.id == projectId).single;
    await updateProject(item.project.copyWith(status: 'archived'));
  }

  @override
  Future<void> deleteProject(String projectId) async {
    deleteCalled = true;
    stored.removeWhere((item) => item.project.id == projectId);
  }

  @override
  Future<String?> getProjectBoard(String projectId) async => stored
      .where(
        (item) =>
            item.project.id == projectId && item.project.ownerId == userId,
      )
      .firstOrNull
      ?.boardId;

  @override
  Future<List<ProjectWithProgress>> getProjectsWithProgress() async {
    if (failLoad) throw StateError('offline');
    return stored.where((item) => item.project.ownerId == userId).toList();
  }
}

ProjectWithProgress sampleProject(
  String id,
  String name, {
  String ownerId = 'user-1',
  String status = 'active',
  String? boardId,
  int total = 0,
  int completed = 0,
}) => ProjectWithProgress(
  project: LearningProject(
    id: id,
    ownerId: ownerId,
    name: name,
    status: status,
  ),
  boardId: boardId ?? 'board-$id',
  totalTaskCount: total,
  completedTaskCount: completed,
);
