import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:skilltrack/core/errors/app_exception.dart';
import 'package:skilltrack/features/kanban/models/kanban_task.dart';
import 'package:skilltrack/features/kanban/models/kanban_status.dart';
import 'package:skilltrack/features/kanban/models/task_tag.dart';
import 'package:skilltrack/features/kanban/models/task_checklist_item.dart';
import 'package:skilltrack/features/kanban/repositories/supabase_kanban_repository.dart';
import 'package:skilltrack/features/ai_task_generation/models/generated_task_draft.dart';
import 'package:skilltrack/features/ai_task_generation/models/generated_milestone_draft.dart';
import 'package:skilltrack/features/projects/repositories/supabase_project_repository.dart';
import 'package:skilltrack/features/projects/models/learning_project.dart';

class _ProjectRepository extends SupabaseProjectRepository {
  _ProjectRepository(super.client);
  @override
  String get currentUserId => 'user';
}

class _KanbanRepository extends SupabaseKanbanRepository {
  _KanbanRepository(super.client);
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
  String failCode = '42703';
  String failMessage = 'internal database column details';
  String? failInsertTable;
  bool failTaskRollback = false;
  bool failStorageDelete = false;

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
        (request.uri.path.startsWith('/storage/') && failStorageDelete) ||
        (request.method == 'DELETE' &&
            table == 'kanban_tasks' &&
            failTaskRollback)) {
      request.response.statusCode = 400;
      request.response.write(
        jsonEncode({'message': failMessage, 'code': failCode}),
      );
    } else if (table == 'projects' &&
        (request.method == 'POST' || request.method == 'PATCH')) {
      final payload = (jsonDecode(body) as Map).cast<String, dynamic>();
      final existing =
          tables['projects']?.firstOrNull ??
          {'id': 'project-1', 'owner_id': 'user'};
      final row = {...existing, ...payload};
      tables['projects'] = [row];
      request.response.write(jsonEncode(row));
    } else if (table == 'kanban_boards' && request.method == 'POST') {
      request.response.write(jsonEncode({'id': 'board-1'}));
    } else if (table == 'create_project_milestone') {
      request.response.write(jsonEncode(tables[table]!.single));
    } else if (table == 'update_task_checklist_item') {
      request.response.write(jsonEncode(tables[table]!.single));
    } else if (table == 'update_kanban_task_tracking' ||
        table == 'save_kanban_task_edit') {
      request.response.write(jsonEncode(tables[table]!.single));
    } else if (table == 'task_attachment_cleanup' &&
        request.method == 'DELETE') {
      request.response.write(jsonEncode(tables[table] ?? []));
      tables[table] = [];
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
        final id = request.uri.queryParameters['id'];
        rows = rows
            .where(
              (row) =>
                  (board == null ||
                      !board.startsWith('eq.') ||
                      row['board_id'] == board.substring(3)) &&
                  (archived == null ||
                      row['is_archived'] == (archived == 'eq.true')) &&
                  (id == null || id == "eq.${row['id']}"),
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
  test(
    'scoped task loading passes only its task ID to dependent queries',
    () async {
      final api = await _ApiFixture.start();
      final client = api.client();
      addTearDown(() async {
        await client.dispose();
        await api.close();
      });
      api.tables['kanban_tasks'] = [
        _task('1', 'board'),
        _task('2', 'board'),
        _task('3', 'other'),
      ];
      final repo = SupabaseKanbanRepository(client);
      expect((await repo.getTask('board', '2'))!.id, '2');
      final taskRequest = api.requests.first;
      expect(taskRequest.queryParameters, containsPair('id', 'eq.2'));
      expect(taskRequest.queryParameters, containsPair('board_id', 'eq.board'));
      for (final uri in api.requests.skip(1)) {
        expect(uri.queryParameters, containsPair('task_id', 'in.("2")'));
      }
    },
  );

  test('edit sends one RPC with the task version and selected tags', () async {
    final api = await _ApiFixture.start();
    final client = api.client();
    addTearDown(() async {
      await client.dispose();
      await api.close();
    });
    final task = KanbanTask.fromMap(_task('1', 'board'));
    api.tables['save_kanban_task_edit'] = [
      {
        'task': {..._task('1', 'board'), 'title': 'Renamed'},
        'tags': [],
        'checklist': [],
        'attachments': [],
      },
    ];
    final repo = SupabaseKanbanRepository(client);

    final saved = await repo.saveTaskEdit(
      task.copyWith(title: 'Renamed'),
      requestId: 'edit-1',
      tagIds: [],
    );

    expect(saved.title, 'Renamed');
    expect(api.requests.single.path, endsWith('/rpc/save_kanban_task_edit'));
    final payload = jsonDecode(api.requestBodies.single) as Map;
    expect(
      payload['p_expected_updated_at'],
      task.updatedAt.toUtc().toIso8601String(),
    );
    expect(payload['p_request_id'], 'edit-1');
    expect(payload['p_add_tag_ids'], isEmpty);
    expect(payload['p_remove_tag_ids'], isEmpty);
    expect(payload['p_changes'], containsPair('title', 'Renamed'));
  });

  test(
    'failed storage cleanup keeps the queue until a later success',
    () async {
      final api = await _ApiFixture.start();
      final client = api.client();
      addTearDown(() async {
        await client.dispose();
        await api.close();
      });
      final repo = _KanbanRepository(client);
      api.tables['task_attachment_cleanup'] = [
        {'storage_path': 'user/task/file'},
      ];
      api.failStorageDelete = true;
      await repo.retryAttachmentCleanup();
      expect(api.tables['task_attachment_cleanup'], hasLength(1));
      expect(api.methods, ['GET', 'DELETE']);
      expect(api.requests.last.path, '/storage/v1/object/task-attachments');

      api.failStorageDelete = false;
      await repo.retryAttachmentCleanup();
      expect(api.methods, ['GET', 'DELETE', 'GET', 'DELETE', 'DELETE', 'GET']);
      expect(api.tables['task_attachment_cleanup'], isEmpty);
    },
  );

  test(
    'checklist updates use an atomic RPC and do not insert a second generic log',
    () async {
      final api = await _ApiFixture.start();
      final client = api.client();
      addTearDown(() async {
        await client.dispose();
        await api.close();
      });
      api.tables['update_task_checklist_item'] = [
        {
          'id': 'item',
          'task_id': 'task',
          'title': 'Read',
          'position': 0,
          'is_completed': true,
          'completed_at': '2026-11-03T10:00:00Z',
        },
      ];
      final repo = SupabaseKanbanRepository(client);
      final item = TaskChecklistItem(
        id: 'item',
        taskId: 'task',
        title: 'Read',
        position: 0,
        isCompleted: true,
        completedAt: DateTime.utc(2026, 11, 3, 9),
      );
      final saved = await repo.updateChecklistItem(item);
      expect(saved.isCompleted, isTrue);
      expect(saved.completedAt, DateTime.utc(2026, 11, 3, 10));
      expect(
        api.requests.single.path,
        '/rest/v1/rpc/update_task_checklist_item',
      );
      expect(jsonDecode(api.requestBodies.single), {
        'p_item_id': 'item',
        'p_title': 'Read',
        'p_position': 0,
        'p_is_completed': true,
      });
    },
  );
  test(
    'explicit progress uses its own activity RPC and keeps the request ID on retries',
    () async {
      final api = await _ApiFixture.start();
      final client = api.client();
      addTearDown(() async {
        await client.dispose();
        await api.close();
      });
      final repo = SupabaseKanbanRepository(client);
      for (final text in ['  ', 'x' * 1001]) {
        await expectLater(
          repo.addProgressUpdate(
            'task',
            text,
            requestId: 'progress-request-0001',
          ),
          throwsA(isA<AppException>()),
        );
      }
      expect(api.requests, isEmpty);
      for (var i = 0; i < 2; i++) {
        await repo.addProgressUpdate(
          'task',
          '  Tested API  ',
          requestId: 'progress-request-0001',
        );
      }
      expect(api.requests, hasLength(2));
      expect(
        api.requests.every(
          (r) => r.path == '/rest/v1/rpc/add_task_progress_update',
        ),
        isTrue,
      );
      for (final body in api.requestBodies) {
        expect(jsonDecode(body), {
          'p_task_id': 'task',
          'p_request_id': 'progress-request-0001',
          'p_text': 'Tested API',
        });
      }
    },
  );

  test(
    'milestone availability checks the current board, project owner and archived flags in one query',
    () async {
      final api = await _ApiFixture.start();
      final client = api.client();
      addTearDown(() async {
        await client.dispose();
        await api.close();
      });
      final repo = _ProjectRepository(client);
      expect(
        await repo.canCreateMilestone(
          projectId: 'project-1',
          boardId: 'board-1',
        ),
        isFalse,
      );
      final query = api.requests.single.queryParameters;
      expect(query['id'], 'eq.board-1');
      expect(query['project_id'], 'eq.project-1');
      expect(query['is_archived'], 'eq.false');
      expect(query['projects.owner_id'], 'eq.user');
      expect(query['projects.status'], 'neq.archived');
      api.tables['kanban_boards'] = [
        {
          'id': 'board-1',
          'projects': {'owner_id': 'user', 'status': 'active'},
        },
      ];
      expect(
        await repo.canCreateMilestone(
          projectId: 'project-1',
          boardId: 'board-1',
        ),
        isTrue,
      );
    },
  );

  test(
    'manual milestone uses one authenticated RPC with a stable request ID and trimmed name',
    () async {
      final api = await _ApiFixture.start();
      final client = api.client();
      addTearDown(() async {
        await client.dispose();
        await api.close();
      });
      api.tables['create_project_milestone'] = [
        {
          'id': 'milestone-1',
          'project_id': 'project-1',
          'title': 'Manual',
          'position': 3,
          'created_at': '2026-11-02T12:00:00Z',
        },
      ];
      final repo = _ProjectRepository(client);
      final saved = await repo.createMilestone(
        boardId: 'board-1',
        title: '  Manual  ',
        requestId: 'manual-request-0001',
      );
      expect(saved.projectId, 'project-1');
      expect(saved.position, 3);
      expect(api.requests.single.path, '/rest/v1/rpc/create_project_milestone');
      expect(jsonDecode(api.requestBodies.single), {
        'p_board_id': 'board-1',
        'p_title': 'Manual',
        'p_request_id': 'manual-request-0001',
      });
      expect(saved.createdAt, DateTime.utc(2026, 11, 2, 12));
      for (final name in ['', '  ', 'x' * 151]) {
        await expectLater(
          repo.createMilestone(
            boardId: 'board-1',
            title: name,
            requestId: 'manual-request-0001',
          ),
          throwsA(isA<AppException>()),
        );
      }
      expect(api.requests, hasLength(1));
    },
  );

  test(
    'manual milestone permission and save errors are actionable without direct-insert fallback',
    () async {
      final api = await _ApiFixture.start();
      final client = api.client();
      addTearDown(() async {
        await client.dispose();
        await api.close();
      });
      final repo = _ProjectRepository(client);
      api.fail = true;
      for (final code in ['42501', '42703']) {
        api.failCode = code;
        await expectLater(
          repo.createMilestone(
            boardId: 'board-1',
            title: 'Manual',
            requestId: 'manual-request-0001',
          ),
          throwsA(
            isA<AppException>().having(
              (e) => e.message,
              'message',
              code == '42501'
                  ? AppErrorMessages.milestoneBoardUnavailable
                  : AppErrorMessages.createMilestoneFailed,
            ),
          ),
        );
      }
      expect(api.requests, hasLength(2));
      expect(
        api.requests.every(
          (r) => r.path.endsWith('/rpc/create_project_milestone'),
        ),
        isTrue,
      );
    },
  );

  test(
    'project repository writes and loads constraints_text, including explicit null clearing',
    () async {
      final api = await _ApiFixture.start();
      final client = api.client();
      addTearDown(() async {
        await client.dispose();
        await api.close();
      });
      final repo = _ProjectRepository(client);
      for (final constraints in [null, '   ', '  Flutter only  ']) {
        final created = await repo.createProject(
          name: 'App',
          description: 'Build',
          constraints: constraints,
        );
        final expected = constraints == '  Flutter only  '
            ? 'Flutter only'
            : null;
        expect(created.project.constraints, expected);
        final sent =
            jsonDecode(api.requestBodies[api.requestBodies.length - 2]) as Map;
        expect(sent['constraints_text'], expected);
      }
      final loaded = await repo.getProject('project-1');
      expect(loaded!.constraints, 'Flutter only');
      final edited = await repo.updateProject(
        loaded.copyWith(constraints: '  Add tests  '),
      );
      expect(edited.constraints, 'Add tests');
      expect(
        (jsonDecode(api.requestBodies.last) as Map)['constraints_text'],
        'Add tests',
      );
      final cleared = await repo.updateProject(
        edited.copyWith(clearConstraints: true),
      );
      expect(cleared.constraints, isNull);
      expect(
        (jsonDecode(api.requestBodies.last) as Map).containsKey(
          'constraints_text',
        ),
        isTrue,
      );
      expect(
        (jsonDecode(api.requestBodies.last) as Map)['constraints_text'],
        isNull,
      );
      expect(api.requests.last.queryParameters['owner_id'], 'eq.user');
      final listed = await repo.getUserProjects();
      expect(listed.single.constraints, isNull);
    },
  );

  test(
    'project repository rejects oversized constraints before writing create or update requests',
    () async {
      final api = await _ApiFixture.start();
      final client = api.client();
      addTearDown(() async {
        await client.dispose();
        await api.close();
      });
      final repo = _ProjectRepository(client);
      final expected = throwsA(
        isA<AppException>().having(
          (error) => error.message,
          'message',
          AppErrorMessages.invalidGenerationConstraints,
        ),
      );
      await expectLater(
        repo.createProject(name: 'App', constraints: 'x' * 1001),
        expected,
      );
      await expectLater(
        repo.updateProject(
          LearningProject(
            id: 'p',
            ownerId: 'user',
            name: 'App',
            status: 'active',
            constraints: 'x' * 1001,
          ),
        ),
        expected,
      );
      expect(api.requests, isEmpty);
    },
  );

  test(
    'timer RPC uses task version and preserves authoritative fields and relations',
    () async {
      final api = await _ApiFixture.start();
      final client = api.client();
      addTearDown(() async {
        await client.dispose();
        await api.close();
      });
      final row = {
        ..._task('1', 'board-1'),
        'status': 'in_progress',
        'elapsed_seconds': 120,
        'tracking_started_at': '2026-10-31T08:00:00Z',
      };
      api.tables['update_kanban_task_tracking'] = [row];
      final task = KanbanTask.fromMap(
        _task('1', 'board-1'),
        tags: [
          TaskTag(
            id: 'tag',
            ownerId: 'user',
            name: 'Study',
            colorHex: '#6750A4',
          ),
        ],
      );
      final repo = SupabaseKanbanRepository(client);
      final moved = await repo.moveTask(task, KanbanStatus.inProgress, 1500);
      expect(
        api.requests.single.path,
        endsWith('/rpc/update_kanban_task_tracking'),
      );
      final payload = jsonDecode(api.requestBodies.single) as Map;
      expect(payload, {
        'p_task_id': task.id,
        'p_action': 'move',
        'p_expected_updated_at': task.updatedAt.toUtc().toIso8601String(),
        'p_status': 'in_progress',
        'p_sort_order': 1500,
      });
      expect(moved.elapsedSeconds, 120);
      expect(moved.trackingStartedAt, DateTime.utc(2026, 10, 31, 8));
      expect(moved.tags, task.tags);
      final paused = {
        ...row,
        'tracking_started_at': null,
        'elapsed_seconds': 180,
      };
      api.tables['update_kanban_task_tracking'] = [paused];
      expect((await repo.setTaskTimerPaused(moved, true)).elapsedSeconds, 180);
      final pausePayload = jsonDecode(api.requestBodies.last) as Map;
      expect(pausePayload['p_action'], 'pause');
      expect(pausePayload.containsKey('p_status'), isFalse);
      expect(pausePayload.containsKey('p_sort_order'), isFalse);
      await repo.setTaskTimerPaused(moved, false);
      expect((jsonDecode(api.requestBodies.last) as Map)['p_action'], 'resume');
    },
  );

  test(
    'stale timer RPC reports a refresh message without exposing backend details',
    () async {
      final api = await _ApiFixture.start()
        ..fail = true
        ..failCode = '40001';
      final client = api.client();
      addTearDown(() async {
        await client.dispose();
        await api.close();
      });
      await expectLater(
        SupabaseKanbanRepository(
          client,
        ).setTaskTimerPaused(KanbanTask.fromMap(_task('1', 'board-1')), false),
        throwsA(
          isA<AppException>().having(
            (e) => e.message,
            'message',
            AppErrorMessages.taskChanged,
          ),
        ),
      );
    },
  );

  test(
    'task summaries include context and archived tasks in one query',
    () async {
      final api = await _ApiFixture.start();
      final client = api.client();
      addTearDown(() async {
        await client.dispose();
        await api.close();
      });
      api.tables['kanban_tasks'] = [
        {
          ..._task('1', 'board-1'),
          'description': 'Build the foundation',
          'deadline': '2026-11-20',
        },
        {
          ..._task('2', 'board-1'),
          'status': 'in_progress',
          'deadline': 'invalid-date',
        },
        {..._task('3', 'board-1', archived: true), 'description': null},
      ];
      final summaries = await SupabaseKanbanRepository(
        client,
      ).getTaskSummaries('board-1');
      expect(summaries.map((task) => task.status), [
        'todo',
        'in_progress',
        'archived',
      ]);
      expect(summaries.first.description, 'Build the foundation');
      expect(summaries.first.deadline, DateTime(2026, 11, 20));
      expect(summaries[1].deadline, isNull);
      expect(summaries.last.description, isEmpty);
      expect(summaries.last.deadline, isNull);
      expect(summaries.map((task) => task.sortOrder), [1000, 2000, 1000]);
      expect(api.requests, hasLength(1));
      expect(
        api.requests.single.queryParameters['select'],
        'title,description,status,deadline,sort_order,is_archived,milestone_id',
      );
      expect(
        api.requests.single.queryParameters,
        isNot(contains('is_archived')),
      );
    },
  );

  test(
    'generated tasks and checklists use one atomic request with a retry ID',
    () async {
      final api = await _ApiFixture.start();
      final client = api.client();
      addTearDown(() async {
        await client.dispose();
        await api.close();
      });
      final drafts = [
        GeneratedTaskDraft(
          title: 'Basics',
          description: 'Build widgets',
          priority: 'low',
          deadline: DateTime(2026, 10, 20),
          position: 0,
          checklist: ['Plan', 'Build'],
        ),
      ];
      final repo = SupabaseKanbanRepository(client);
      for (var retry = 0; retry < 2; retry++) {
        await repo.createGeneratedTasks(
          'board-1',
          drafts,
          requestId: 'stable-operation-123',
        );
      }
      expect(api.methods, ['POST', 'POST']);
      expect(
        api.requests.every(
          (uri) => uri.path.endsWith('/rpc/save_generated_tasks'),
        ),
        isTrue,
      );
      expect(api.requestBodies[0], api.requestBodies[1]);
      final payload = jsonDecode(api.requestBodies.first) as Map;
      expect(payload['p_board_id'], 'board-1');
      expect(payload['p_request_id'], 'stable-operation-123');
      final task = (payload['p_tasks'] as List).single as Map;
      expect(task['checklist'], ['Plan', 'Build']);
      expect(task['deadline'], '2026-10-20');
      expect(
        task.containsKey('sort_order'),
        isFalse,
      ); // Allocated under a DB lock.
      expect(task.containsKey('owner_id'), isFalse);
    },
  );

  test(
    'milestone batch uses versioned atomic RPC and preserves retry payload',
    () async {
      final api = await _ApiFixture.start();
      final client = api.client();
      addTearDown(() async {
        await client.dispose();
        await api.close();
      });
      final group = GeneratedMilestoneDraft(
        localId: 'draft-stage',
        title: 'Authentication',
        position: 0,
      );
      final tasks = [
        GeneratedTaskDraft(
          title: 'Build login',
          description: 'Connect authentication',
          priority: 'medium',
          deadline: DateTime(2026, 12, 1),
          position: 0,
          checklist: ['Build', 'Test'],
          milestone: group,
        ),
      ];
      final repository = SupabaseKanbanRepository(client);
      await repository.createGeneratedTasks(
        'board-1',
        tasks,
        requestId: 'milestone-operation-123',
      );
      await repository.createGeneratedTasks(
        'board-1',
        tasks,
        requestId: 'milestone-operation-123',
      );
      expect(
        api.requests.every(
          (uri) =>
              uri.path.endsWith('/rpc/save_generated_tasks_with_milestones'),
        ),
        isTrue,
      );
      expect(api.methods, ['POST', 'POST']);
      expect(api.requestBodies.first, api.requestBodies.last);
      final body = jsonDecode(api.requestBodies.first) as Map;
      expect(body['p_request_id'], 'milestone-operation-123');
      final task = (body['p_tasks'] as List).single as Map;
      expect(task['milestone'], group.toJson());
      expect(task['draftTaskId'], tasks.single.localId);
      expect(task['checklist'], ['Build', 'Test']);
    },
  );

  test(
    'failed milestone batch never falls back to separate client writes',
    () async {
      final api = await _ApiFixture.start()
        ..failInsertTable = 'save_generated_tasks_with_milestones';
      final client = api.client();
      addTearDown(() async {
        await client.dispose();
        await api.close();
      });
      await expectLater(
        SupabaseKanbanRepository(client).createGeneratedTasks('board-1', [
          GeneratedTaskDraft(
            title: 'Build login',
            description: 'Connect auth',
            priority: 'medium',
            deadline: DateTime(2026, 12, 1),
            position: 0,
            milestone: GeneratedMilestoneDraft(
              localId: 'new',
              title: 'Auth',
              position: 0,
            ),
          ),
        ]),
        throwsA(isA<AppException>()),
      );
      expect(api.requests, hasLength(1));
      expect(
        api.requests.single.path,
        endsWith('/rpc/save_generated_tasks_with_milestones'),
      );
    },
  );

  test(
    'failed atomic generation does not attempt client compensation',
    () async {
      final api = await _ApiFixture.start()
        ..failInsertTable = 'save_generated_tasks';
      final client = api.client();
      addTearDown(() async {
        await client.dispose();
        await api.close();
      });
      await expectLater(
        SupabaseKanbanRepository(client).createGeneratedTasks('board-1', [
          GeneratedTaskDraft(
            title: 'Build',
            description: 'Build it',
            priority: 'medium',
            deadline: DateTime(2026, 10, 20),
            position: 0,
            checklist: ['Plan'],
          ),
        ]),
        throwsA(isA<AppException>()),
      );
      expect(api.methods, ['POST']);
      expect(api.requests.single.path, endsWith('/rpc/save_generated_tasks'));
    },
  );

  test('reorder and checklist deletion each use one transaction RPC', () async {
    final api = await _ApiFixture.start();
    final client = api.client();
    addTearDown(() async {
      await client.dispose();
      await api.close();
    });
    final repo = SupabaseKanbanRepository(client);
    await repo.deleteChecklistItem('item-1');
    expect(
      api.requests.single.path,
      endsWith('/rpc/delete_task_checklist_item'),
    );
    expect(jsonDecode(api.requestBodies.single), {'p_item_id': 'item-1'});
  });

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
  for (final code in ['42703', 'PGRST204']) {
    test(
      'missing deadline metadata $code reports setup failure without retrying the insert',
      () async {
        final api = await _ApiFixture.start()
          ..fail = true
          ..failCode = code
          ..failMessage =
              "column kanban_tasks.deadline_has_time does not exist";
        final client = api.client();
        addTearDown(() async {
          await client.dispose();
          await api.close();
        });
        await expectLater(
          SupabaseKanbanRepository(
            client,
          ).createTask(KanbanTask.fromMap(_task('1', 'board-1'))),
          throwsA(
            isA<AppException>().having(
              (e) => e.message,
              'message',
              AppErrorMessages.taskSetupIncomplete,
            ),
          ),
        );
        expect(api.requests.length, 1);
        expect(api.methods.single, 'POST');
      },
    );
  }
}
