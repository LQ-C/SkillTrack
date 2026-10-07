import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/errors/app_exception.dart';
import '../models/learning_project.dart';
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
    } on AuthException catch (error) {
      throw AppException(error.message);
    } on PostgrestException catch (error) {
      throw AppException(error.message);
    } catch (_) {
      throw const AppException(
        'Unable to complete the request. Please check your connection.',
      );
    }
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
      throw const AppException(
        'Unable to create the project. Please try again.',
      );
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
        return projects.map((project) {
          final boardId = boardByProject[project.id];
          final tasks = taskRows.where((task) => task['board_id'] == boardId);
          return ProjectWithProgress(
            project: project,
            boardId: boardId,
            totalTaskCount: tasks.length,
            completedTaskCount: tasks
                .where((task) => task['status'] == 'completed')
                .length,
          );
        }).toList();
      });
}
