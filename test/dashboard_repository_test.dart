import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:skilltrack/features/dashboard/repositories/dashboard_repository.dart';

class FixtureRepository extends SupabaseDashboardRepository {
  FixtureRepository(super.client);
  @override
  String get owner => 'fixture-owner';
}

void main() {
  test('queries are scoped, bounded and reuse session authorization', () async {
    final requests = <http.Request>[];
    final client = SupabaseClient(
      'https://fixture.invalid',
      'fixture-key',
      httpClient: MockClient((r) async {
        requests.add(r);
        return http.Response(
          jsonEncode([]),
          200,
          request: r,
          headers: {'content-type': 'application/json', 'content-range': '*/0'},
        );
      }),
    );
    final repository = FixtureRepository(client);
    final now = DateTime.parse('2026-11-14T02:00:00Z');
    final projects = await repository.projects(now);
    expect(projects.active, 0);
    expect(projects.today, 0);
    expect(projects.stalled, 0);
    await repository.session(now);
    final tasks = requests.where((r) => r.url.path.endsWith('kanban_tasks'));
    expect(tasks.length, 2);
    for (final r in tasks) {
      final q = r.url.queryParameters;
      expect(q['kanban_boards.projects.owner_id'], 'eq.fixture-owner');
      expect(q['kanban_boards.projects.status'], 'eq.active');
      expect(q['kanban_boards.is_archived'], 'eq.false');
      expect(q['is_archived'], 'eq.false');
      expect(q['status'], anyOf('neq.completed', 'eq.in_progress'));
      expect(q['limit'], anyOf('0', '3'));
    }
    final session = requests.last;
    expect(session.url.path, endsWith('/rpc/my_mentorship_sessions'));
    expect(session.url.queryParameters['status'], 'eq.accepted');
    expect(session.url.queryParameters['limit'], '1');
    expect(requests.any((r) => r.url.path.contains('functions')), false);
    await client.dispose();
  });
}
