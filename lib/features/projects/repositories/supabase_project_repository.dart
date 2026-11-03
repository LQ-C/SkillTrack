import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/errors/app_exception.dart';
import '../../../core/constants/app_constants.dart';
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
  }) => _guard(() async {
    final userId = _userId();
    final row = await _client
        .from('projects')
        .insert({
          'owner_id': userId,
          'name': name,
          'description': description,
          'constraints_text': _constraints(constraints),
          'status': 'active',
          'start_date': startDate?.toIso8601String().split('T').first,
          'end_date': endDate?.toIso8601String().split('T').first,
        })
        .select()
        .single();
    final project = LearningProject.fromMap(row);
    try {
      final board = await _client
          .from('kanban_boards')
          .insert({'project_id': project.id, 'name': 'Kanban Board'})
          .select('id')
          .single();
      return ProjectWithProgress(
        project: project,
        boardId: board['id'].toString(),
        totalTaskCount: 0,
        completedTaskCount: 0,
      );
    } catch (_) {
      await _client
          .from('projects')
          .delete()
          .eq('id', project.id)
          .eq('owner_id', userId);
      throw const AppException(AppErrorMessages.createProjectFailed);
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
