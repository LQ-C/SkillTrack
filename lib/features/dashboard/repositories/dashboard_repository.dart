import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/utils/date_formatter.dart';
import '../../projects/models/project_with_progress.dart';
import '../../projects/models/learning_project.dart';
import '../../projects/repositories/supabase_project_repository.dart';
import '../../tutor_management/models/tutor_models.dart';

class DashboardProjects {
  DashboardProjects(this.active, this.today, this.stalled, this.items);
  final int active, today, stalled;
  final List<ProjectWithProgress> items;
}

abstract class DashboardRepository {
  String? get userId;
  Stream<String?> get userChanges;
  Future<DashboardProjects> projects(DateTime now);
  Future<MentorshipSession?> session(DateTime now);
}

class SupabaseDashboardRepository implements DashboardRepository {
  SupabaseDashboardRepository(this.client);
  final SupabaseClient client;
  @override
  String? get userId => client.auth.currentUser?.id;
  @override
  Stream<String?> get userChanges =>
      client.auth.onAuthStateChange.map((e) => e.session?.user.id).distinct();
  String get owner => userId ?? (throw StateError('Signed out'));
  static const join =
      '*,kanban_boards!inner(project_id,is_archived,projects!inner(id,name,owner_id,status))';
  PostgrestFilterBuilder<List<Map<String, dynamic>>> tasks() => client
      .from('kanban_tasks')
      .select(join)
      .eq('kanban_boards.projects.owner_id', owner)
      .eq('kanban_boards.projects.status', 'active')
      .eq('kanban_boards.is_archived', false)
      .eq('is_archived', false)
      .neq('status', 'completed');
  @override
  Future<DashboardProjects> projects(DateTime now) async {
    final today = DateFormatter.today(now: now);
    final start = DateFormatter.fromMalaysia(today).toIso8601String();
    final end = DateFormatter.fromMalaysia(
      today.add(const Duration(days: 1)),
    ).toIso8601String();

    final results = await Future.wait<dynamic>([
      client
          .from('projects')
          .count()
          .eq('owner_id', owner)
          .eq('status', 'active'),
      tasks().gte('deadline', start).lt('deadline', end).limit(0).count(),
      tasks().or('is_stalled.eq.true,stagnation_score.gte.70').limit(0).count(),
      _projectCards(),
    ]);
    final items = results[3] as List<ProjectWithProgress>;
    return DashboardProjects(
      results[0] as int,
      results[1].count as int,
      results[2].count as int,
      items,
    );
  }

  Future<List<ProjectWithProgress>> _projectCards() async {
    final rows = await client
        .from('projects')
        .select()
        .eq('owner_id', owner)
        .eq('status', 'active')
        .order('created_at', ascending: false)
        .order('id')
        .limit(3);
    return SupabaseProjectRepository(client).progressForProjects(
      rows.map((row) => LearningProject.fromMap(row)).toList(),
    );
  }

  @override
  Future<MentorshipSession?> session(DateTime now) async {
    owner;
    final rows = await client
        .rpc('my_mentorship_sessions')
        .eq('status', 'accepted')
        .gt('starts_at', now.toUtc().toIso8601String())
        .order('starts_at')
        .order('id')
        .limit(1);
    return (rows as List).isEmpty
        ? null
        : MentorshipSession.fromJson(Map<String, dynamic>.from(rows.first));
  }
}
