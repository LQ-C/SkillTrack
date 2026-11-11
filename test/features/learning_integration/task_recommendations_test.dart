import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skilltrack/app/app_theme.dart';
import 'package:skilltrack/core/errors/app_exception.dart';
import 'package:skilltrack/features/kanban/models/kanban_status.dart';
import 'package:skilltrack/features/kanban/viewmodels/kanban_view_model.dart';
import 'package:skilltrack/features/kanban/widgets/task_details_sheet.dart';
import 'package:skilltrack/features/learning_integration/models/resource_recommendation.dart';
import 'package:skilltrack/features/learning_integration/repositories/recommendation_repository.dart';
import 'package:skilltrack/features/learning_integration/view_models/task_recommendations_view_model.dart';
import 'package:skilltrack/features/learning_integration/widgets/task_recommendations_section.dart';
import '../kanban/fake_repository.dart';

const recommendation = ResourceRecommendation(
  resourceId: 'resource-1',
  title: 'Flutter layout tutorial',
  summary: 'Learn Row and Column widgets.',
  type: 'Video',
);

class FakeRecommendations implements RecommendationRepository {
  int calls = 0;
  @override
  String? currentUserId = 'user-1';
  final sessions = StreamController<String?>.broadcast(sync: true);
  @override
  Stream<String?> get userChanges => sessions.stream;
  final modes = <RecommendationRequestMode>[];
  void signOut() {
    currentUserId = null;
    sessions.add(null);
  }

  bool fail = false;
  List<ResourceRecommendation> items = [recommendation];
  Completer<List<ResourceRecommendation>>? pending;
  @override
  Future<List<ResourceRecommendation>> recommendationsForTask(
    String taskId, {
    RecommendationRequestMode mode = RecommendationRequestMode.automatic,
  }) async {
    calls++;
    modes.add(mode);
    if (pending != null) return pending!.future;
    if (fail) {
      throw const AppException(AppErrorMessages.loadRecommendationsFailed);
    }
    return items;
  }
}

Future<
  ({
    KanbanViewModel tasks,
    TaskRecommendationsViewModel model,
    FakeRecommendations repo,
    FakeKanbanRepository tasksRepo,
  })
>
fixture({bool stalled = true}) async {
  final tasksRepo = FakeKanbanRepository(
    tasks: [
      sampleTask(
        't',
        'Build Flutter layout',
        KanbanStatus.inProgress,
      ).copyWith(isStalled: stalled),
    ],
  );
  final tasks = KanbanViewModel(tasksRepo);
  await tasks.initialize('board-1');
  final repo = FakeRecommendations();
  final model = TaskRecommendationsViewModel(repo, taskId: 't', tasks: tasks);
  addTearDown(() {
    model.dispose();
    unawaited(repo.sessions.close());
    tasks.dispose();
  });
  return (tasks: tasks, model: model, repo: repo, tasksRepo: tasksRepo);
}

void main() {
  test('model keeps resource identity and rejects malformed responses', () {
    final item = ResourceRecommendation.fromMap({
      'resource_id': 'id',
      'title': 'Title',
      'summary': 'Summary',
      'type': 'Article',
    });
    expect(item.resourceId, 'id');
    expect(
      () => ResourceRecommendation.fromMap({'title': 'Invalid'}),
      throwsFormatException,
    );
  });
  test('non-stalled task does not load; becoming stalled loads once', () async {
    final f = await fixture(stalled: false);
    expect(f.repo.calls, 0);
    f.tasksRepo.stored = [f.tasksRepo.stored.single.copyWith(isStalled: true)];
    await f.tasks.refresh();
    await Future<void>.delayed(Duration.zero);
    expect(f.repo.calls, 1);
    expect(f.model.items.single.resourceId, 'resource-1');
    await f.tasks.refresh();
    expect(f.repo.calls, 1);
  });
  test('resume clears results and ignores pending responses', () async {
    final f = await fixture();
    await Future<void>.delayed(Duration.zero);
    f.repo.pending = Completer();
    final pending = f.model.retry();
    await f.tasks.resumeTask('t');
    expect(f.model.eligible, true);
    expect(f.model.hasRequested, false);
    expect(f.model.items, isEmpty);
    f.repo.pending!.complete([recommendation]);
    await pending;
    expect(f.model.items, isEmpty);
    expect(f.model.isLoading, false);
  });
  test('retries are guarded; failures preserve retry state', () async {
    final f = await fixture();
    await Future<void>.delayed(Duration.zero);
    f.repo.fail = true;
    await f.model.retry();
    expect(f.model.errorMessage, isNotNull);
    f.repo.fail = false;
    f.repo.pending = Completer();
    final request = f.model.retry();
    final calls = f.repo.calls;
    await f.model.retry();
    expect(f.repo.calls, calls);
    f.repo.pending!.complete([recommendation]);
    await request;
    expect(f.model.errorMessage, isNull);
  });
  testWidgets(
    'Task Details shows read-only cards, rebuilds do not request again, Resume clears automatic results but keeps manual action',
    (tester) async {
      final f = await fixture();
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: TaskDetailsSheet(
              taskId: 't',
              viewModel: f.tasks,
              recommendations: f.model,
              onEdit: (_) {},
              fullScreen: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Learning resources'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(find.text('Learning resources'), findsOneWidget);
      expect(find.text(recommendation.title), findsOneWidget);
      expect(find.text('Open'), findsNothing);
      await f.tasks.refresh();
      await tester.pumpAndSettle();
      expect(f.repo.calls, 1);
      await tester.scrollUntilVisible(
        find.text('Resume Task'),
        -200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Resume Task'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Get Recommendations'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(find.text('Learning resources'), findsOneWidget);
      expect(find.text('Get Recommendations'), findsOneWidget);
      expect(find.text(recommendation.title), findsNothing);
    },
  );
  testWidgets(
    'loading, empty, error and retry states remain usable at narrow width',
    (tester) async {
      final f = await fixture();
      await tester.pump();
      await tester.binding.setSurfaceSize(const Size(320, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: SingleChildScrollView(
              child: TaskRecommendationsSection(viewModel: f.model),
            ),
          ),
        ),
      );
      f.repo.pending = Completer();
      final pending = f.model.retry();
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      f.repo.pending!.complete([]);
      await pending;
      await tester.pump();
      expect(
        find.text('No relevant learning resources found yet.'),
        findsOneWidget,
      );
      f.repo.pending = null;
      f.repo.fail = true;
      await f.model.retry();
      await tester.pump();
      expect(find.text('Retry'), findsOneWidget);
      f.repo.fail = false;
      await tester.ensureVisible(find.text('Retry'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text(recommendation.title), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  test(
    'manual non-stalled requests load only on demand and can refresh',
    () async {
      final f = await fixture(stalled: false);
      expect(f.model.eligible, true);
      expect(f.model.hasRequested, false);
      expect(f.repo.calls, 0);
      await f.model.getRecommendations();
      expect(f.model.items, [recommendation]);
      expect(f.repo.modes, [RecommendationRequestMode.manual]);
      await f.tasks.refresh();
      expect(f.repo.calls, 1);
      await f.model.getRecommendations();
      expect(f.repo.calls, 2);
      expect(f.tasks.allTasks.single.isStalled, false);
      expect(f.tasks.allTasks.single.status, KanbanStatus.inProgress);
    },
  );
  test(
    'manual duplicate taps and automatic transitions share one request',
    () async {
      final f = await fixture(stalled: false);
      f.repo.pending = Completer();
      final pending = f.model.getRecommendations();
      await f.model.getRecommendations();
      await f.model.retry();
      f.tasksRepo.stored = [
        f.tasksRepo.stored.single.copyWith(isStalled: true),
      ];
      await f.tasks.refresh();
      expect(f.repo.calls, 1);
      f.repo.pending!.complete([recommendation]);
      await pending;
      expect(f.model.items, [recommendation]);
      await f.tasks.refresh();
      expect(f.repo.calls, 1);
    },
  );
  test(
    'manual tap during automatic load does not submit a second request',
    () async {
      final f = await fixture();
      await Future<void>.delayed(Duration.zero);
      f.repo.pending = Completer();
      final pending = f.model.retry();
      final calls = f.repo.calls;
      await f.model.getRecommendations();
      expect(f.repo.calls, calls);
      expect(f.repo.modes.last, RecommendationRequestMode.automatic);
      f.repo.pending!.complete([recommendation]);
      await pending;
      f.repo.pending = null;
      await f.model.getRecommendations();
      expect(f.repo.modes.last, RecommendationRequestMode.manual);
      expect(f.model.items, [recommendation]);
    },
  );
  test(
    'manual stale responses cannot restore changed, completed or archived tasks',
    () async {
      for (final change in ['edit', 'complete', 'archive', 'project']) {
        final f = await fixture(stalled: false);
        f.repo.pending = Completer();
        final pending = f.model.getRecommendations();
        final task = f.tasksRepo.stored.single;
        if (change == 'project') {
          f.model.setProjectActive(false);
        } else {
          f.tasksRepo.stored = [
            task.copyWith(
              title: change == 'edit' ? 'Changed task' : task.title,
              status: change == 'complete'
                  ? KanbanStatus.completed
                  : task.status,
              isArchived: change == 'archive',
            ),
          ];
          await f.tasks.refresh();
        }
        f.repo.pending!.complete([recommendation]);
        await pending;
        expect(f.model.items, isEmpty);
        expect(f.model.eligible, change == 'edit');
        expect(f.model.isLoading, false);
      }
    },
  );
  test(
    'sign-out immediately clears results and ignores late success or failure',
    () async {
      for (final fail in [false, true]) {
        final f = await fixture(stalled: false);
        await f.model.getRecommendations();
        f.repo.pending = Completer();
        final pending = f.model.getRecommendations();
        f.repo.signOut();
        expect(f.model.items, isEmpty);
        expect(f.model.eligible, false);
        if (fail) {
          f.repo.pending!.completeError(StateError('late failure'));
        } else {
          f.repo.pending!.complete([recommendation]);
        }
        await pending;
        expect(f.model.items, isEmpty);
        expect(f.model.errorMessage, isNull);
        final calls = f.repo.calls;
        await f.model.getRecommendations();
        expect(f.repo.calls, calls);
      }
    },
  );
  test('disposed screen ignores an in-flight manual response', () async {
    final f = await fixture(stalled: false);
    final model = TaskRecommendationsViewModel(
      f.repo,
      taskId: 't',
      tasks: f.tasks,
    );
    f.repo.pending = Completer();
    final pending = model.getRecommendations();
    model.dispose();
    f.repo.pending!.complete([recommendation]);
    await pending;
    expect(model.items, isEmpty);
  });
  testWidgets(
    'manual button stays available with loading, empty, error and retry states',
    (tester) async {
      final f = await fixture(stalled: false);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: TaskDetailsSheet(
              taskId: 't',
              viewModel: f.tasks,
              recommendations: f.model,
              onEdit: (_) {},
              fullScreen: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Get Recommendations'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(find.text('Get Recommendations'), findsOneWidget);
      expect(
        find.text('No relevant learning resources found yet.'),
        findsNothing,
      );
      expect(f.repo.calls, 0);
      f.repo.pending = Completer();
      await tester.tap(find.text('Get Recommendations'));
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Get Recommendations'),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('Get Recommendations'));
      expect(f.repo.calls, 1);
      f.repo.pending!.complete([]);
      await tester.pumpAndSettle();
      expect(
        find.text('No relevant learning resources found yet.'),
        findsOneWidget,
      );
      f.repo.pending = null;
      f.repo.fail = true;
      await tester.tap(find.text('Get Recommendations'));
      await tester.pumpAndSettle();
      expect(find.text('Retry'), findsOneWidget);
      f.repo.fail = false;
      await tester.ensureVisible(find.text('Retry'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text(recommendation.title), findsOneWidget);
      expect(find.text('Get Recommendations'), findsOneWidget);
      expect(find.text('Open'), findsNothing);
      expect(
        f.repo.modes.every((mode) => mode == RecommendationRequestMode.manual),
        true,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
