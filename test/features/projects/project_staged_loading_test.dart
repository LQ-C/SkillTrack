import 'package:flutter/material.dart';
import 'package:skilltrack/features/projects/views/project_dashboard_screen.dart';
import '../kanban/fake_repository.dart';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:skilltrack/features/projects/models/learning_project.dart';
import 'package:skilltrack/features/projects/models/project_with_progress.dart';
import 'package:skilltrack/features/projects/repositories/project_repository.dart';
import 'package:skilltrack/features/projects/viewmodels/project_dashboard_view_model.dart';
import 'fake_project_repository.dart';

class StagedProjects extends FakeProjectRepository
    implements ProjectProgressSource, ProjectSessionSource {
  int listCalls = 0, progressCalls = 0;
  final changes = StreamController<String?>.broadcast(sync: true);
  Completer<List<LearningProject>>? pendingList;
  Completer<List<ProjectWithProgress>>? pendingProgress;
  bool failProgress = false;
  @override
  Stream<String?> get userChanges => changes.stream;
  @override
  Future<List<LearningProject>> getUserProjects() async {
    listCalls++;
    return pendingList == null ? super.getUserProjects() : pendingList!.future;
  }

  @override
  Future<List<ProjectWithProgress>> progressForProjects(
    List<LearningProject> projects,
  ) async {
    progressCalls++;
    if (failProgress) throw StateError('offline');
    return pendingProgress == null
        ? getProjectsWithProgress()
        : pendingProgress!.future;
  }
}

void main() {
  testWidgets(
    'cards render unknown progress then show counts, and retry keeps cards usable',
    (tester) async {
      final repository = StagedProjects()
        ..stored.add(
          sampleProject('a', 'Visible project', total: 4, completed: 1),
        );
      final progress = Completer<List<ProjectWithProgress>>();
      repository.pendingProgress = progress;
      await tester.pumpWidget(
        MaterialApp(
          home: ProjectDashboardScreen(
            projectRepository: repository,
            kanbanRepository: FakeKanbanRepository(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      expect(find.text('Visible project'), findsOneWidget);
      expect(find.text('Loading progress…'), findsOneWidget);
      expect(find.text('0%'), findsNothing);
      expect(find.text('0 of 0 tasks completed'), findsNothing);
      progress.complete(repository.stored);
      await tester.pumpAndSettle();
      expect(find.text('25%'), findsOneWidget);
      expect(find.text('1 of 4 tasks completed'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await repository.changes.close();
    },
  );
  testWidgets(
    'progress failure shows retry without removing the project card',
    (tester) async {
      final repository = StagedProjects()
        ..stored.add(
          sampleProject('a', 'Visible project', total: 4, completed: 1),
        )
        ..failProgress = true;
      await tester.pumpWidget(
        MaterialApp(
          home: ProjectDashboardScreen(
            projectRepository: repository,
            kanbanRepository: FakeKanbanRepository(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Visible project'), findsOneWidget);
      expect(find.text('0%'), findsNothing);
      repository.failProgress = false;
      await tester.tap(find.text('Retry progress').last);
      await tester.pumpAndSettle();
      expect(find.text('25%'), findsOneWidget);
      expect(repository.listCalls, 1);
      expect(repository.progressCalls, 2);
      await tester.pumpWidget(const SizedBox());
      await repository.changes.close();
    },
  );

  late StagedProjects repo;
  late ProjectDashboardViewModel vm;
  setUp(() {
    repo = StagedProjects()
      ..stored.add(sampleProject('a', 'Alpha', total: 4, completed: 1));
    vm = ProjectDashboardViewModel(
      repo,
      requestTimeout: const Duration(milliseconds: 40),
    );
  });
  tearDown(() async {
    vm.dispose();
    await repo.changes.close();
  });
  test(
    'list is visible and project can open before progress completes',
    () async {
      repo.pendingProgress = Completer();
      final pending = vm.load();
      await Future<void>.delayed(Duration.zero);
      expect(vm.projects.single.project.name, 'Alpha');
      expect(vm.isLoading, false);
      expect(vm.isProgressLoading, true);
      expect(vm.hasProgress('a'), false);
      expect(vm.activeCount, 1);
      expect(await vm.boardFor('a'), 'board-a');
      repo.pendingProgress!.complete(repo.stored);
      await pending;
      expect(vm.hasProgress('a'), true);
      expect(vm.projects.single.progress, .25);
    },
  );
  test(
    'hanging list times out, retry deduplicates and late list is ignored',
    () async {
      final old = Completer<List<LearningProject>>();
      repo.pendingList = old;
      await Future.wait([vm.load(), vm.load()]);
      expect(repo.listCalls, 1);
      expect(vm.errorMessage, contains('timed out'));
      expect(vm.isLoading, false);
      repo.pendingList = null;
      await vm.load();
      expect(repo.listCalls, 2);
      expect(vm.errorMessage, isNull);
      old.complete([sampleProject('old', 'Old').project]);
      await Future<void>.delayed(Duration.zero);
      expect(vm.projects.single.project.id, 'a');
    },
  );
  test(
    'progress failure or timeout preserves cards; retry only progress and ignores late data',
    () async {
      repo.failProgress = true;
      await vm.load();
      expect(vm.projects, hasLength(1));
      expect(vm.progressError, isNotNull);
      expect(vm.isProgressLoading, false);
      repo.failProgress = false;
      final old = Completer<List<ProjectWithProgress>>();
      repo.pendingProgress = old;
      await Future.wait([vm.retryProgress(), vm.retryProgress()]);
      expect(repo.progressCalls, 2);
      expect(vm.progressError, contains('timed out'));
      expect(repo.listCalls, 1);
      repo.pendingProgress = null;
      await vm.retryProgress();
      expect(vm.projects.single.progress, .25);
      expect(vm.progressError, isNull);
      old.complete([sampleProject('a', 'Wrong', total: 10, completed: 9)]);
      await Future<void>.delayed(Duration.zero);
      expect(vm.projects.single.progress, .25);
      expect(vm.projects.single.project.name, 'Alpha');
    },
  );
  test(
    'refresh preserves cards/search/filter and mutation reconciles summaries',
    () async {
      await vm.load();
      vm.search('alp');
      vm.filter('active');
      repo.pendingList = Completer();
      final pending = vm.load();
      await Future<void>.delayed(Duration.zero);
      expect(vm.visibleProjects, hasLength(1));
      expect(vm.hasProgress('a'), true);
      repo.pendingList!.complete(repo.stored.map((p) => p.project).toList());
      await pending;
      repo.pendingList = null;
      expect(await vm.markCompleted(vm.projects.single), true);
      expect(vm.completedCount, 1);
      expect(vm.activeCount, 0);
      expect(vm.visibleProjects, isEmpty);
    },
  );
  test(
    'logout and new account never accept previous progress responses',
    () async {
      final old = Completer<List<ProjectWithProgress>>();
      repo.pendingProgress = old;
      final pending = vm.load();
      await Future<void>.delayed(Duration.zero);
      repo.userId = null;
      repo.changes.add(null);
      expect(vm.projects, isEmpty);
      expect(vm.isProgressLoading, false);
      repo.userId = 'new';
      repo.changes.add('new');
      repo.pendingProgress = null;
      await vm.load();
      expect(vm.projects, isEmpty);
      old.complete(repo.stored);
      await pending;
      expect(vm.projects, isEmpty);
      expect(vm.totalCount, 0);
    },
  );
}
