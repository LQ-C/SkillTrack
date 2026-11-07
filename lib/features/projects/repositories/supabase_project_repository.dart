import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/errors/app_exception.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/utils/operation_id.dart';
import '../../ai_task_generation/models/generated_task_draft.dart';
import '../models/learning_project.dart';
import '../models/project_milestone.dart';
import '../models/project_with_progress.dart';
import 'project_repository.dart';

class SupabaseProjectRepository implements ProjectRepository {
  SupabaseProjectRepository(this._client);
  final SupabaseClient _client;

  @override
  String? get currentUserId => _client.auth.currentUser?.id;

  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on AppException {
      rethrow;
    } on AuthException {
      throw const AppException(AppErrorMessages.signInFailed);
    } catch (_) {
      throw const AppException(AppErrorMessages.requestFailed);
    }
  }

  String? _constraints(String? value) {
    final normalized = LearningProject.normalizeConstraints(value);
    if ((normalized?.length ?? 0) >
        AppLimits.maxTaskGenerationConstraintsLength) {
      throw const AppException(AppErrorMessages.invalidGenerationConstraints);
    }
    return normalized;
  }

  String _userId() {
    final id = currentUserId;
    if (id == null) throw const AppException('Sign in to view your projects.');
    return id;
  }

  @override
  Future<void> signIn(String email, String password) => _guard(() async {
    await _client.auth.signInWithPassword(email: email, password: password);
  });

  @override
  Future<List<ProjectMilestone>> getProjectMilestones(String projectId) =>
      _guard(() async {
        if (await getProject(projectId) == null) return [];
        final rows = await _client
            .from('project_milestones')
            .select()
            .eq('project_id', projectId)
            .order('position')
            .order('id');
        return rows.map(ProjectMilestone.fromMap).toList();
      });

  @override
  Future<bool> canCreateMilestone({
    required String projectId,
    required String boardId,
  }) => _guard(() async {
    final board = await _client
        .from('kanban_boards')
        .select('id,projects!inner(owner_id,status)')
        .eq('id', boardId)
        .eq('project_id', projectId)
        .eq('is_archived', false)
        .eq('projects.owner_id', _userId())
        .neq('projects.status', 'archived')
        .maybeSingle();
    return board != null;
  });

  @override
  Future<ProjectMilestone> createMilestone({
    required String boardId,
    required String title,
    required String requestId,
  }) => _guard(() async {
    _userId();
    final error = ProjectMilestone.validateTitle(title);
    if (error != null) throw AppException(error);
    try {
      final row = await _client
          .rpc(
            'create_project_milestone',
            params: {
              'p_board_id': boardId,
              'p_title': title.trim(),
              'p_request_id': requestId,
            },
          )
          .single();
      return ProjectMilestone.fromMap(row);
    } on PostgrestException catch (error) {
      throw AppException(
        error.code == '42501'
            ? AppErrorMessages.milestoneBoardUnavailable
            : AppErrorMessages.createMilestoneFailed,
      );
    } catch (_) {
      throw const AppException(AppErrorMessages.createMilestoneFailed);
    }
  });

  @override
  Future<List<LearningProject>> getUserProjects() => _guard(() async {
    final rows = await _client
        .from('projects')
        .select()
        .eq('owner_id', _userId())
        .order('created_at', ascending: false);
    return rows.map(LearningProject.fromMap).toList();
  });

  @override
  Future<LearningProject?> getProject(String projectId) => _guard(() async {
    final row = await _client
        .from('projects')
        .select()
        .eq('id', projectId)
        .eq('owner_id', _userId())
        .maybeSingle();
    return row == null ? null : LearningProject.fromMap(row);
  });

  @override
  Future<ProjectWithProgress> createProject({
    required String name,
    String? description,
    String? constraints,
    DateTime? startDate,
    DateTime? endDate,
  }) => saveNewProject(
    requestId: createOperationId(),
    name: name,
    description: description,
    constraints: constraints,
    startDate: startDate,
    endDate: endDate,
  );

  @override
  Future<ProjectWithProgress> saveNewProject({
    required String requestId,
    required String name,
    String? description,
    String? constraints,
    DateTime? startDate,
    DateTime? endDate,
    List<GeneratedTaskDraft>? generatedTasks,
  }) => _guard(() async {
    _userId();
    try {
      final result =
          await _client.rpc(
                'save_new_skilltrack_project',
                params: {
                  'p_request_id': requestId,
                  'p_name': name,
                  'p_description': description,
                  'p_constraints': _constraints(constraints),
                  'p_start_date': startDate?.toIso8601String().split('T').first,
                  'p_end_date': endDate?.toIso8601String().split('T').first,
                  'p_tasks': generatedTasks
                      ?.map((task) => task.toRevisionJson())
                      .toList(),
                },
              )
              as Map<String, dynamic>;
      return ProjectWithProgress(
        project: LearningProject.fromMap(
          result['project'] as Map<String, dynamic>,
        ),
        boardId: result['board_id'] as String,
        totalTaskCount: result['total_task_count'] as int,
        completedTaskCount: 0,
      );
    } on PostgrestException catch (error) {
      // Only an explicit database rejection makes it safe to edit the payload.
      final code = error.code;
      if (error.hint == 'skilltrack_project_setup') {
        throw const ProjectWriteRejected(AppErrorMessages.createProjectFailed);
      }
      if (code == 'P0001' ||
          (code != null &&
              RegExp(r'^(22|23|40|42)[0-9A-Z]{3}$').hasMatch(code))) {
        throw const ProjectWriteRejected();
      }
      rethrow;
    }
  });

  @override
  Future<LearningProject> updateProject(LearningProject project) => _guard(
    () async {
      final row = await _client
          .from('projects')
          .update({
            'name': project.name,
            'description': project.description,
            'constraints_text': _constraints(project.constraints),
            'status': project.status,
            'start_date': project.startDate?.toIso8601String().split('T').first,
            'end_date': project.endDate?.toIso8601String().split('T').first,
          })
          .eq('id', project.id)
          .eq('owner_id', _userId())
          .select()
          .single();
      return LearningProject.fromMap(row);
    },
  );

  @override
  Future<void> archiveProject(String projectId) => _guard(() async {
    await _client
        .from('projects')
        .update({'status': 'archived'})
        .eq('id', projectId)
        .eq('owner_id', _userId())
        .select('id')
        .single();
  });

  @override
  Future<void> deleteProject(String projectId) => _guard(() async {
    await _client
        .from('projects')
        .delete()
        .eq('id', projectId)
        .eq('owner_id', _userId())
        .select('id')
        .single();
  });

  @override
  Future<String?> getProjectBoard(String projectId) => _guard(() async {
    final project = await getProject(projectId);
    if (project == null) return null;
    final board = await _client
        .from('kanban_boards')
        .select('id')
        .eq('project_id', projectId)
        .eq('is_archived', false)
        .maybeSingle();
    return board?['id']?.toString();
  });

  @override
  Future<List<ProjectWithProgress>> getProjectsWithProgress() =>
      _guard(() async {
        final projects = await getUserProjects();
        if (projects.isEmpty) return [];
        final boards = await _client
            .from('kanban_boards')
            .select('id,project_id,is_archived')
            .inFilter('project_id', projects.map((p) => p.id).toList());
        final activeBoards = boards.where(
          (board) => board['is_archived'] != true,
        );
        final boardByProject = {
          for (final board in activeBoards)
            board['project_id'].toString(): board['id'].toString(),
        };
        final boardIds = boardByProject.values.toList();
        final taskRows = boardIds.isEmpty
            ? <Map<String, dynamic>>[]
            : await _client
                  .from('kanban_tasks')
                  .select('board_id,status,is_archived')
                  .inFilter('board_id', boardIds)
                  .eq('is_archived', false);
        final counts = <String, ({int total, int completed})>{};
        for (final task in taskRows) {
          final boardId = task['board_id'].toString();
          final previous = counts[boardId] ?? (total: 0, completed: 0);
          counts[boardId] = (
            total: previous.total + 1,
            completed:
                previous.completed + (task['status'] == 'completed' ? 1 : 0),
          );
        }
        return projects.map((project) {
          final boardId = boardByProject[project.id];
          final count = counts[boardId];
          return ProjectWithProgress(
            project: project,
            boardId: boardId,
            totalTaskCount: count?.total ?? 0,
            completedTaskCount: count?.completed ?? 0,
          );
        }).toList();
      });
}
