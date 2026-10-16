import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:skilltrack/core/errors/app_exception.dart';
import 'package:skilltrack/features/kanban/repositories/supabase_kanban_repository.dart';
import 'package:skilltrack/features/ai_task_generation/models/generated_task_draft.dart';
import 'package:skilltrack/features/projects/repositories/supabase_project_repository.dart';

class _ProjectRepository extends SupabaseProjectRepository {
  _ProjectRepository(super.client);
  @override
  String get currentUserId => 'user';
}

class _ApiFixture {
  _ApiFixture(this.server);
  final HttpServer server;
  late final StreamSubscription<HttpRequest> subscription;
  final requests = <Uri>[];
  final methods = <String>[];
  final requestBodies = <String>[];
  final tables = <String, List<Map<String, dynamic>>>{};
  bool fail = false;
  String? failInsertTable;
  bool failTaskRollback = false;

  static Future<_ApiFixture> start() async {
    final fixture = _ApiFixture(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    fixture.subscription = fixture.server.listen(fixture._respond);
    return fixture;
  }

  SupabaseClient client() =>
      SupabaseClient('http://127.0.0.1:${server.port}', 'test-public-key');

  Future<void> _respond(HttpRequest request) async {
    requests.add(request.uri);
    methods.add(request.method);
    final body = await utf8.decoder.bind(request).join();
    requestBodies.add(body);
    request.response.headers.contentType = ContentType.json;
    final table = request.uri.pathSegments.last;
    if (fail ||
        (request.method == 'POST' && table == failInsertTable) ||
        (request.method == 'DELETE' &&
            table == 'kanban_tasks' &&
            failTaskRollback)) {
      request.response.statusCode = 400;
      request.response.write(
        jsonEncode({
          'message': 'internal database column details',
          'code': '42703',
        }),
      );
    } else {
      var rows = List<Map<String, dynamic>>.of(tables[table] ?? []);
      if (table == 'kanban_tasks') {
        if (request.method == 'POST') {
          final inserted = (jsonDecode(body) as List)
              .cast<Map<String, dynamic>>();
          rows = [
            for (final row in inserted.reversed)
              {
                'id': 'generated-${row['sort_order']}',
                'sort_order': row['sort_order'],
              },
          ];
        }
        final board = request.uri.queryParameters['board_id'];
        final archived = request.uri.queryParameters['is_archived'];
        rows = rows
            .where(
              (row) =>
                  (board == null ||
                      !board.startsWith('eq.') ||
                      row['board_id'] == board.substring(3)) &&
                  (archived == null ||
                      row['is_archived'] == (archived == 'eq.true')),
            )
            .toList();
        final order = request.uri.queryParameters['order'] ?? '';
        if (order.startsWith('updated_at.desc')) {
          rows.sort(
            (a, b) => b['updated_at'].toString().compareTo(
              a['updated_at'].toString(),
            ),
          );
        }
        if (order.startsWith('sort_order.desc')) {
          rows.sort(
            (a, b) =>
                (b['sort_order'] as int).compareTo(a['sort_order'] as int),
          );
        }
      }
      if (table == 'task_checklist_items' &&
          (request.uri.queryParameters['order'] ?? '').startsWith(
            'position.desc',
          )) {
        rows.sort(
          (a, b) => (b['position'] as int).compareTo(a['position'] as int),
        );
      }
      request.response.write(jsonEncode(rows));
    }
    await request.response.close();
  }

  Future<void> close() async {
    await subscription.cancel();
    await server.close(force: true);
  }
}

Map<String, dynamic> _task(String id, String board, {bool archived = false}) =>
    {
      'id': id,
      'board_id': board,
      'title': 'Task $id',
      'status': id == '2' ? 'completed' : 'todo',
      'priority': 'medium',
      'sort_order': id == '2' ? 2000 : 1000,
      'is_archived': archived,
      'stagnation_score': 55,
      'is_stalled': false,
      'last_activity_at': '2026-10-14T08:00:00Z',
      'updated_at': id == '2' ? '2026-10-14T08:00:00Z' : '2026-10-13T08:00:00Z',
    };

void main() {
  test('generated tasks use one trusted batch insert payload', () async {
    final api = await _ApiFixture.start();
    final client = api.client();
    addTearDown(() async {
      await client.dispose();
      await api.close();
    });
    await SupabaseKanbanRepository(client).createGeneratedTasks('board-1', [
      GeneratedTaskDraft(
        title: 'Basics',
        description: 'Widgets',
        priority: 'low',
        deadline: DateTime(2026, 10, 16),
        position: 0,
      ),
      GeneratedTaskDraft(
        title: 'Practice',
        description: 'Build a view',
        priority: 'medium',
        deadline: DateTime(2026, 10, 20),
        position: 1,
      ),
    ]);
    expect(api.requests.length, 1);
    expect(api.requests.single.pathSegments.last, 'kanban_tasks');
    expect(api.requests.single.queryParameters['select'], 'id,sort_order');
    final rows = jsonDecode(api.requestBodies.single) as List<dynamic>;
    expect(rows.length, 2);
    expect(rows.map((row) => row['sort_order']), [1000, 2000]);
    expect(
      rows.every(
        (row) =>
            row['board_id'] == 'board-1' &&
            row['status'] == 'todo' &&
            row['is_archived'] == false,
      ),
      isTrue,
    );
    expect(rows.first['priority'], 'low');
    for (final field in [
      'id',
      'project_id',
      'user_id',
      'created_at',
      'updated_at',
      'stagnation_score',
      'is_stalled',
    ]) {
      expect(rows.first.containsKey(field), isFalse);
    }
  });

  test(
    'generated checklists are inserted once with returned task IDs',
    () async {
      final api = await _ApiFixture.start();
      final client = api.client();
      addTearDown(() async {
        await client.dispose();
        await api.close();
      });
      await SupabaseKanbanRepository(client).createGeneratedTasks('board-1', [
        GeneratedTaskDraft(
          title: 'First',
          description: '',
          priority: 'medium',
          deadline: DateTime(2026, 10, 16),
          position: 0,
          checklist: ['Plan', 'Build'],
        ),
        GeneratedTaskDraft(
          title: 'Second',
          description: '',
          priority: 'high',
          deadline: DateTime(2026, 10, 17),
          position: 1,
          checklist: ['Review'],
        ),
      ]);
      expect(api.methods, ['POST', 'POST']);
      expect(api.requests.map((uri) => uri.pathSegments.last), [
        'kanban_tasks',
        'task_checklist_items',
      ]);
      expect(api.requests.first.queryParameters['select'], 'id,sort_order');
      final checklistRows = (jsonDecode(api.requestBodies.last) as List)
          .cast<Map<String, dynamic>>();
      expect(checklistRows, [
        {
          'task_id': 'generated-1000',
          'title': 'Plan',
          'position': 0,
          'is_completed': false,
        },
        {
          'task_id': 'generated-1000',
          'title': 'Build',
          'position': 1,
          'is_completed': false,
        },
        {
          'task_id': 'generated-2000',
          'title': 'Review',
          'position': 0,
          'is_completed': false,
        },
      ]);
      for (final field in ['id', 'created_at', 'completed_at']) {
        expect(checklistRows.first.containsKey(field), isFalse);
      }
    },
  );

  test('failed generated task insert skips checklists', () async {
    final api = await _ApiFixture.start()
      ..failInsertTable = 'kanban_tasks';
    final client = api.client();
    addTearDown(() async {
      await client.dispose();
      await api.close();
    });
    await expectLater(
      SupabaseKanbanRepository(client).createGeneratedTasks('board-1', [
        GeneratedTaskDraft(
          title: 'First',
          description: '',
          priority: 'medium',
          deadline: DateTime(2026, 10, 16),
          position: 0,
          checklist: ['Plan'],
        ),
      ]),
      throwsA(isA<AppException>()),
    );
    expect(api.requests.map((uri) => uri.pathSegments.last), ['kanban_tasks']);
  });

  for (final rollbackFails in [false, true]) {
    test(
      'checklist failure keeps the save error when rollback fails: $rollbackFails',
      () async {
        final api = await _ApiFixture.start()
          ..failInsertTable = 'task_checklist_items'
          ..failTaskRollback = rollbackFails;
        final client = api.client();
        addTearDown(() async {
          await client.dispose();
          await api.close();
        });
        await expectLater(
          SupabaseKanbanRepository(client).createGeneratedTasks('board-1', [
            GeneratedTaskDraft(
              title: 'First',
              description: '',
              priority: 'medium',
              deadline: DateTime(2026, 10, 16),
              position: 0,
              checklist: ['Plan'],
            ),
          ]),
          throwsA(isA<AppException>()),
        );
        expect(api.methods, ['POST', 'POST', 'DELETE']);
        final rollback = api.requests.last;
        expect(rollback.pathSegments.last, 'kanban_tasks');
        expect(rollback.queryParameters['id'], contains('generated-1000'));
        expect(rollback.queryParameters.containsKey('board_id'), isFalse);
      },
    );
  }
  for (final archived in [false, true]) {
    test(
      '${archived ? 'archived' : 'active'} tasks keep relations and use one query per table',
      () async {
        final api = await _ApiFixture.start();
        final client = api.client();
        addTearDown(() async {
          await client.dispose();
          await api.close();
        });
        api.tables.addAll({
          'kanban_tasks': [
            _task('1', 'board', archived: archived),
            _task('2', 'board', archived: archived),
            _task('other', 'another'),
          ],
          'task_tag_links': [
            {'task_id': '2', 'tag_id': 'green'},
            {'task_id': '1', 'tag_id': 'red'},
            {'task_id': '1', 'tag_id': 'green'},
            {'task_id': '1', 'tag_id': 'unavailable'},
          ],
          'task_tags': [
            {
              'id': 'red',
              'owner_id': 'user',
              'name': 'Red',
              'color_hex': '#E53935',
            },
            {
              'id': 'green',
              'owner_id': 'user',
              'name': 'Green',
              'color_hex': '#00897B',
            },
          ],
          'task_checklist_items': [
            {
              'id': 'second-task',
              'task_id': '2',
              'title': 'Other task',
              'position': 0,
            },
            {'id': 'first', 'task_id': '1', 'title': 'First', 'position': 0},
            {'id': 'second', 'task_id': '1', 'title': 'Second', 'position': 1},
          ],
          'task_attachments': [
            {
              'id': 'a',
              'task_id': '1',
              'file_name': 'one.txt',
              'storage_path': 'one',
            },
            {
              'id': 'b',
              'task_id': '2',
              'file_name': 'two.txt',
              'storage_path': 'two',
            },
          ],
        });
        final repo = SupabaseKanbanRepository(client);
        final tasks = archived
            ? await repo.getArchivedTasks('board')
            : await repo.getTasks('board');
        expect(tasks.map((task) => task.id), ['2', '1']);
        final first = tasks.singleWhere((task) => task.id == '1');
        final second = tasks.singleWhere((task) => task.id == '2');
        expect(first.tags.map((tag) => tag.id), ['red', 'green']);
        expect(first.tags.first.colorHex, '#E53935');
        expect(first.checklistItems.map((item) => item.id), [
          'second',
          'first',
        ]);
        expect(first.attachments.single.fileName, 'one.txt');
        expect(second.tags.single.id, 'green');
        expect(second.checklistItems.single.id, 'second-task');
        expect(second.attachments.single.fileName, 'two.txt');
        expect(first.stagnationScore, 55);
        expect(first.lastActivityAt, DateTime.utc(2026, 10, 14, 8));
        expect(first.isArchived, archived);
        expect(api.requests.length, 5);
        for (final table in api.tables.keys.where(
          (table) => table != 'kanban_tasks',
        )) {
          expect(
            api.requests.where((uri) => uri.pathSegments.last == table).length,
            1,
          );
        }
        final query = api.requests.singleWhere(
          (uri) => uri.pathSegments.last == 'kanban_tasks',
        );
        expect(query.queryParameters['board_id'], 'eq.board');
        expect(query.queryParameters['is_archived'], 'eq.$archived');
        expect(
          query.queryParameters['order'],
          archived ? 'updated_at.desc.nullslast' : 'sort_order.desc.nullslast',
        );
      },
    );
  }

  test(
    'project progress groups counts once and keeps empty and archived boards correct',
    () async {
      final api = await _ApiFixture.start();
      final client = api.client();
      addTearDown(() async {
        await client.dispose();
        await api.close();
      });
      api.tables.addAll({
        'projects': [
          for (final id in ['p1', 'p2', 'p3', 'empty'])
            {'id': id, 'owner_id': 'user', 'name': id, 'status': 'active'},
        ],
        'kanban_boards': [
          {'id': 'b1', 'project_id': 'p1', 'is_archived': false},
          {'id': 'b2', 'project_id': 'p2', 'is_archived': false},
          {'id': 'b3', 'project_id': 'p3', 'is_archived': true},
        ],
        'kanban_tasks': [
          _task('1', 'b1'),
          _task('2', 'b1'),
          _task('3', 'b2'),
          _task('ignored', 'b1', archived: true),
        ],
      });
      final rows = await _ProjectRepository(client).getProjectsWithProgress();
      final byId = {for (final row in rows) row.project.id: row};
      expect(byId['p1']!.totalTaskCount, 2);
      expect(byId['p1']!.completedTaskCount, 1);
      expect(byId['p1']!.progress, .5);
      expect(byId['p2']!.totalTaskCount, 1);
      expect(byId['p2']!.completedTaskCount, 0);
      for (final id in ['p3', 'empty']) {
        expect(byId[id]!.boardId, isNull);
        expect(byId[id]!.totalTaskCount, 0);
        expect(byId[id]!.progress, 0);
      }
      expect(api.requests.length, 3);
      expect(
        api.requests
            .singleWhere((uri) => uri.pathSegments.last == 'projects')
            .queryParameters['owner_id'],
        'eq.user',
      );
      expect(
        api.requests
            .singleWhere((uri) => uri.pathSegments.last == 'kanban_tasks')
            .queryParameters['is_archived'],
        'eq.false',
      );
    },
  );

  test('repository errors do not expose backend details to the UI', () async {
    final api = await _ApiFixture.start();
    api.fail = true;
    final client = api.client();
    addTearDown(() async {
      await client.dispose();
      await api.close();
    });
    final expected = throwsA(
      isA<AppException>().having(
        (error) => error.message,
        'message',
        AppErrorMessages.requestFailed,
      ),
    );
    await expectLater(
      SupabaseKanbanRepository(client).getTasks('board'),
      expected,
    );
    await expectLater(_ProjectRepository(client).getUserProjects(), expected);
    await expectLater(
      SupabaseKanbanRepository(
        client,
      ).signIn('user@example.test', 'test-password'),
      throwsA(
        isA<AppException>().having(
          (error) => error.message,
          'message',
          AppErrorMessages.signInFailed,
        ),
      ),
    );
  });
}
