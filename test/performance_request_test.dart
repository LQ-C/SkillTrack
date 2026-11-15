import 'dart:async';
import 'package:skilltrack/features/educational_content/repositories/content_repository.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skilltrack/features/educational_content/viewmodels/content_library_view_model.dart';
import 'package:skilltrack/features/educational_content/models/learning_resource.dart';
import 'package:skilltrack/features/kanban/viewmodels/kanban_view_model.dart';
import 'package:skilltrack/features/kanban/models/task_tag.dart';
import 'package:skilltrack/features/kanban/models/kanban_task.dart';
import 'package:skilltrack/features/kanban/models/kanban_status.dart';
import 'marketplace/content_test.dart' show FakeContentRepository, sample;
import 'features/kanban/fake_repository.dart';

class CountContent extends FakeContentRepository {
  int permissionReads = 0, bookmarkReads = 0, listReads = 0;
  @override
  Future<({bool mentor, bool publisher})> permissions() async {
    permissionReads++;
    return super.permissions();
  }

  @override
  Future<Set<String>> bookmarks() async {
    bookmarkReads++;
    return {};
  }

  @override
  Future<List<LearningResource>> list({
    required bool mine,
    required String search,
    String? category,
    String? level,
    String? kind,
    required int offset,
  }) async {
    listReads++;
    if (this.fail) throw StateError('offline');
    return [sample];
  }
}

class CountKanban extends FakeKanbanRepository {
  CountKanban()
    : super(
        tasks: [
          KanbanTask.fromMap({
            'id': 't',
            'board_id': 'board-1',
            'title': 'Task',
            'status': 'todo',
          }),
        ],
      );
  int tagReads = 0;
  @override
  Future<List<TaskTag>> getUserTags(String user) async {
    tagReads++;
    return super.getUserTags(user);
  }
}

class SessionContent extends CountContent implements ContentSessionSource {
  final changes = StreamController<String?>.broadcast(sync: true);
  Completer<List<LearningResource>>? pending;
  @override
  Stream<String?> get userChanges => changes.stream;
  @override
  Future<List<LearningResource>> list({
    required bool mine,
    required String search,
    String? category,
    String? level,
    String? kind,
    required int offset,
  }) {
    if (pending != null) {
      listReads++;
      return pending!.future;
    }
    return super.list(
      mine: mine,
      search: search,
      category: category,
      level: level,
      kind: kind,
      offset: offset,
    );
  }
}

void main() {
  test(
    'timer pause reconciles authoritative task without board/catalogue reload',
    () async {
      final repo = CountKanban();
      final vm = KanbanViewModel(repo);
      await vm.initialize('board-1');
      await vm.moveTask('t', KanbanStatus.inProgress);
      repo.boardReads = repo.tagReads = 0;
      final version = vm.activityVersion;
      expect(await vm.setTaskTimerPaused('t', true), true);
      expect(repo.boardReads, 0);
      expect(repo.tagReads, 0);
      expect(vm.activityVersion, version + 1);
      expect(vm.tasks(KanbanStatus.inProgress).single.isTracking, false);
      vm.dispose();
    },
  );

  test(
    'Library metadata is reused only for filters/pages and refreshed explicitly',
    () async {
      final repo = CountContent();
      final vm = ContentLibraryViewModel(repo);
      await vm.load();
      vm.category = 'Programming';
      await vm.load(refreshMetadata: false);
      await vm.load(append: true);
      expect(repo.permissionReads, 1);
      expect(repo.bookmarkReads, 1);
      expect(repo.listReads, 3);
      await vm.load();
      expect(repo.permissionReads, 2);
      expect(repo.bookmarkReads, 2);
      repo.userId = 'another';
      await vm.load(refreshMetadata: false);
      expect(repo.permissionReads, 3);
      expect(repo.bookmarkReads, 3);
      vm.dispose();
    },
  );
  test(
    'duplicate Library reads share work and late responses after logout are rejected',
    () async {
      final repo = SessionContent();
      final vm = ContentLibraryViewModel(repo);
      await vm.load();
      final pending = Completer<List<LearningResource>>();
      repo.pending = pending;
      final a = vm.load(refreshMetadata: false);
      final b = vm.load(refreshMetadata: false);
      await Future<void>.delayed(Duration.zero);
      expect(repo.listReads, 2);
      repo.changes.add(null);
      expect(vm.resources, isEmpty);
      expect(vm.bookmarks, isEmpty);
      expect(vm.accessLoaded, false);
      pending.complete([sample]);
      await Future.wait([a, b]);
      expect(vm.resources, isEmpty);
      repo.pending = null;
      repo.changes.add('student');
      await vm.load(refreshMetadata: false);
      expect(repo.permissionReads, 2);
      vm.dispose();
      await repo.changes.close();
    },
  );
  test(
    'failed filter keeps content and can recover with an explicit refresh',
    () async {
      final repo = CountContent();
      final vm = ContentLibraryViewModel(repo);
      await vm.load();
      repo.fail = true;
      await vm.load(refreshMetadata: false);
      expect(vm.error, isNotNull);
      expect(vm.resources.single.id, sample.id);
      expect(vm.loading, false);
      repo.fail = false;
      await vm.load();
      expect(vm.error, isNull);
      expect(repo.permissionReads, 2);
      vm.dispose();
    },
  );

  test('measure pagination metadata and ordinary move requests', () async {
    final content = CountContent();
    final library = ContentLibraryViewModel(content);
    await library.load();
    content.permissionReads = content.bookmarkReads = content.listReads = 0;
    final timer = Stopwatch()..start();
    await library.load(append: true);
    timer.stop();
    expect(content.permissionReads, 0);
    expect(content.bookmarkReads, 0);
    expect(content.listReads, 1);
    debugPrint(
      'MEASURE pagination permission=${content.permissionReads} bookmarks=${content.bookmarkReads} list=${content.listReads} local_us=${timer.elapsedMicroseconds}',
    );
    final tasks = CountKanban();
    final board = KanbanViewModel(tasks);
    await board.initialize('board-1');
    tasks.boardReads = tasks.tagReads = 0;
    timer.reset();
    timer.start();
    await board.moveTask('t', KanbanStatus.inProgress);
    timer.stop();
    expect(tasks.boardReads, 1);
    expect(tasks.tagReads, 0);
    debugPrint(
      'MEASURE move board=${tasks.boardReads} tags=${tasks.tagReads} local_us=${timer.elapsedMicroseconds}',
    );
    board.dispose();
    library.dispose();
  });
}
