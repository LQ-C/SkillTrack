import 'dart:async';
import 'dart:convert';

import '../kanban/fake_repository.dart';
import 'package:skilltrack/core/errors/app_exception.dart';

import 'package:skilltrack/features/ai_task_generation/models/generated_task_draft.dart';
import 'package:skilltrack/features/ai_task_generation/models/task_generation_request.dart';
import 'package:skilltrack/features/ai_task_generation/repositories/ai_task_generation_repository.dart';
import 'package:skilltrack/features/projects/models/learning_project.dart';
import 'package:skilltrack/features/projects/models/project_milestone.dart';
import 'package:skilltrack/features/projects/models/project_with_progress.dart';
import 'package:skilltrack/features/projects/repositories/project_repository.dart';

class FakeTaskGenerationRepository implements TaskGenerationRepository {
  int calls = 0;
  List<ProjectMilestone> lastMilestones = [];
  String? lastProjectId;
  String lastConstraints = '';
  String lastRevisionConstraints = '';
  bool fail = false;
  Completer<List<GeneratedTaskDraft>>? pending;
  List<GeneratedTaskDraft>? result;
  TaskGenerationMode? lastMode;
  List<ExistingTaskSummary> lastExistingTasks = [];
  DateTime? lastStartDate;
  DateTime? lastEndDate;
  int revisionCalls = 0;
  bool failRevision = false;
  Completer<List<GeneratedTaskDraft>>? pendingRevision;
  List<GeneratedTaskDraft>? revisionResult;
  TaskGenerationMode? lastSourceMode;
  String? lastFeedback;
  List<GeneratedTaskDraft> lastCurrentDraft = [];

  @override
  Future<List<GeneratedTaskDraft>> generate({
    required String title,
    required String description,
    required DateTime startDate,
    required DateTime endDate,
    TaskGenerationMode mode = TaskGenerationMode.initial,
    List<ExistingTaskSummary> existingTasks = const [],
    String constraints = '',
    String? projectId,
    List<ProjectMilestone> existingMilestones = const [],
  }) async {
    calls++;
    lastConstraints = constraints;
    lastMilestones = existingMilestones;
    lastProjectId = projectId;
    lastMode = mode;
    lastExistingTasks = existingTasks;
    lastStartDate = startDate;
    lastEndDate = endDate;
    if (pending != null) return pending!.future;
    if (fail) throw StateError('generation failed');
    return result ??
        [
          for (var index = 0; index < 3; index++)
            GeneratedTaskDraft(
              title: 'Step ${index + 1}',
              description: description,
              priority: 'medium',
              deadline: startDate.add(Duration(days: index)),
              position: index,
            ),
        ];
  }

  @override
  Future<List<GeneratedTaskDraft>> revise({
    required String title,
    required String description,
    required DateTime startDate,
    required DateTime endDate,
    required TaskGenerationMode sourceMode,
    required String feedback,
    required List<GeneratedTaskDraft> currentDraft,
    List<ExistingTaskSummary> existingTasks = const [],
    String constraints = '',
    String? projectId,
    List<ProjectMilestone> existingMilestones = const [],
  }) async {
    revisionCalls++;
    lastRevisionConstraints = constraints;
    lastMilestones = existingMilestones;
    lastProjectId = projectId;
    lastSourceMode = sourceMode;
    lastFeedback = feedback;
    lastCurrentDraft = List.of(currentDraft);
    lastExistingTasks = List.of(existingTasks);
    if (pendingRevision != null) return pendingRevision!.future;
    if (failRevision) throw StateError('revision failed');
    return revisionResult ?? List.of(currentDraft);
  }
}

class FakeProjectRepository implements ProjectRepository {
  FakeProjectRepository({
    this.userId = 'user-1',
    List<ProjectWithProgress>? items,
  }) : stored = List.of(items ?? []);
  final milestones = <ProjectMilestone>[];
  @override
  Future<List<ProjectMilestone>> getProjectMilestones(String projectId) async =>
      milestones.where((group) => group.projectId == projectId).toList();
  int milestoneCreateCalls = 0;
  bool failMilestoneCreate = false, loseMilestoneResponseOnce = false;
  Completer<void>? milestonePending;
  final milestoneRequestIds = <String>[];
  final _milestoneReceipts = <String, ProjectMilestone>{};
  @override
  Future<bool> canCreateMilestone({
    required String projectId,
    required String boardId,
  }) async => stored.any(
    (item) =>
        item.project.id == projectId &&
        item.boardId == boardId &&
        item.project.ownerId == userId &&
        item.project.status != 'archived',
  );
  @override
  Future<ProjectMilestone> createMilestone({
    required String boardId,
    required String title,
    required String requestId,
  }) async {
    milestoneCreateCalls++;
    milestoneRequestIds.add(requestId);
    await milestonePending?.future;
    if (failMilestoneCreate) {
      throw const AppException(AppErrorMessages.createMilestoneFailed);
    }
    final item = stored
        .where(
          (p) =>
              p.boardId == boardId &&
              p.project.ownerId == userId &&
              p.project.status != 'archived',
        )
        .firstOrNull;
    if (item == null) {
      throw const AppException(AppErrorMessages.milestoneBoardUnavailable);
    }
    final key = '$userId:$requestId';
    final receipt = _milestoneReceipts[key];
    if (receipt != null) return receipt;
    final existing = milestones.where((m) => m.projectId == item.project.id);
    final position = existing.isEmpty
        ? 0
        : existing.map((m) => m.position).reduce((a, b) => a > b ? a : b) + 1;
    final created = ProjectMilestone(
      id: 'milestone-${_nextId++}',
      projectId: item.project.id,
      title: title.trim(),
      position: position,
    );
    milestones.add(created);
    _milestoneReceipts[key] = created;
    if (loseMilestoneResponseOnce) {
      loseMilestoneResponseOnce = false;
      throw const AppException(AppErrorMessages.createMilestoneFailed);
    }
    return created;
  }

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
    String? constraints,
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
      constraints: LearningProject.normalizeConstraints(constraints),
      status: 'active',
      startDate: startDate,
      endDate: endDate,
    );
    if (failBoardCreation) {
      throw const ProjectWriteRejected(AppErrorMessages.createProjectFailed);
    }
    final item = ProjectWithProgress(
      project: project,
      boardId: 'board-$id',
      totalTaskCount: 0,
      completedTaskCount: 0,
    );
    stored.add(item);
    return item;
  }

  FakeKanbanRepository? generatedTaskRepository;
  bool loseProjectResponseOnce = false;
  final projectRequests = <({String id, String payload})>[];
  final _projectReceipts = <String, ProjectWithProgress>{};

  @override
  Future<ProjectWithProgress> saveNewProject({
    required String requestId,
    required String name,
    String? description,
    String? constraints,
    DateTime? startDate,
    DateTime? endDate,
    List<GeneratedTaskDraft>? generatedTasks,
  }) async {
    projectRequests.add((
      id: requestId,
      payload: jsonEncode([
        name,
        description,
        constraints,
        startDate?.toIso8601String(),
        endDate?.toIso8601String(),
        generatedTasks?.map((task) => task.toRevisionJson()).toList(),
      ]),
    ));
    final key = '$userId:${generatedTasks != null}:$requestId';
    final receipt = _projectReceipts[key];
    if (receipt != null) return receipt;
    final created = await createProject(
      name: name,
      description: description,
      constraints: constraints,
      startDate: startDate,
      endDate: endDate,
    );
    if (generatedTasks != null) {
      final tasks = generatedTaskRepository ??= FakeKanbanRepository();
      try {
        await tasks.createGeneratedTasks(
          created.boardId!,
          generatedTasks,
          requestId: requestId,
        );
      } catch (_) {
        if (tasks.generatedRequests.containsKey(requestId)) {
          _projectReceipts[key] = created.copyWith(
            totalTaskCount: generatedTasks.length,
          );
        } else {
          stored.removeWhere((item) => item.project.id == created.project.id);
        }
        rethrow;
      }
    }
    final saved = created.copyWith(totalTaskCount: generatedTasks?.length ?? 0);
    _projectReceipts[key] = saved;
    if (loseProjectResponseOnce) {
      loseProjectResponseOnce = false;
      throw StateError('response lost');
    }
    return saved;
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
