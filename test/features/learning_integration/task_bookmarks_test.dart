import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skilltrack/features/learning_integration/models/resource_recommendation.dart';
import 'package:skilltrack/features/learning_integration/repositories/bookmark_repository.dart';
import 'package:skilltrack/features/learning_integration/view_models/task_bookmarks_view_model.dart';
import 'package:skilltrack/features/learning_integration/widgets/saved_resources_section.dart';

const resource = ResourceRecommendation(
  resourceId: 'r',
  title: 'Flutter tutorial',
  summary: 'Build apps',
  type: 'Video',
);

class FakeBookmarks implements BookmarkRepository {
  @override
  String? currentUserId = 'owner';
  final changes = StreamController<String?>.broadcast(sync: true);
  @override
  Stream<String?> get userChanges => changes.stream;
  final saved = <String, List<ResourceRecommendation>>{};
  Completer<void>? gate;
  bool fail = false;
  int writes = 0;
  @override
  Future<List<ResourceRecommendation>> savedResources(String id) async =>
      List.of(saved[id] ?? []);
  @override
  Future<void> setBookmark(String task, String id, bool value) async {
    writes++;
    if (gate != null) await gate!.future;
    if (fail) throw StateError('failure');
    saved[task] = value ? [resource] : [];
  }
}

void main() {
  test(
    'save/remove, duplicate taps, failures and reopen retain consistent state',
    () async {
      final repo = FakeBookmarks();
      final model = TaskBookmarksViewModel(repo, 'task');
      await Future<void>.delayed(Duration.zero);
      repo.gate = Completer<void>();
      final save = model.toggle(resource);
      await model.toggle(resource);
      expect(repo.writes, 1);
      repo.gate!.complete();
      await save;
      expect(model.contains('r'), true);
      repo.gate = null;
      repo.fail = true;
      await model.toggle(resource);
      expect(model.contains('r'), true);
      expect(model.errorMessage, isNotNull);
      repo.fail = false;
      model.dispose();
      final reopened = TaskBookmarksViewModel(repo, 'task');
      await Future<void>.delayed(Duration.zero);
      expect(reopened.contains('r'), true);
      await reopened.toggle(resource);
      expect(reopened.items, isEmpty);
      reopened.dispose();
      await repo.changes.close();
    },
  );
  test('account switch ignores an in-flight save', () async {
    final repo = FakeBookmarks();
    final model = TaskBookmarksViewModel(repo, 'task');
    await Future<void>.delayed(Duration.zero);
    repo.gate = Completer<void>();
    final save = model.toggle(resource);
    repo.currentUserId = 'other';
    repo.changes.add('other');
    repo.gate!.complete();
    await save;
    expect(model.items, isEmpty);
    expect(model.active, false);
    model.dispose();
    await repo.changes.close();
  });
  test('independent task scopes and disposed responses', () async {
    final repo = FakeBookmarks();
    final first = TaskBookmarksViewModel(repo, 'first');
    final second = TaskBookmarksViewModel(repo, 'second');
    await Future<void>.delayed(Duration.zero);
    await first.toggle(resource);
    expect(second.items, isEmpty);
    await second.toggle(resource);
    await first.toggle(resource);
    expect(second.contains('r'), true);
    repo.gate = Completer<void>();
    final pending = second.toggle(resource);
    second.dispose();
    repo.gate!.complete();
    await pending;
    first.dispose();
    await repo.changes.close();
  });
  testWidgets(
    'recommendation toggle and saved list synchronize through one model',
    (tester) async {
      final repo = FakeBookmarks();
      final model = TaskBookmarksViewModel(repo, 'task');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                BookmarkButton(model: model, resource: resource),
                SavedResourcesSection(model: model),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('No saved resources yet.'), findsOneWidget);
      await tester.tap(find.byTooltip('Save resource to task'));
      await tester.pumpAndSettle();
      expect(find.text('Flutter tutorial'), findsOneWidget);
      expect(find.byTooltip('Remove saved resource'), findsNWidgets(2));
      await tester.tap(find.byTooltip('Remove saved resource').last);
      await tester.pumpAndSettle();
      expect(find.text('No saved resources yet.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
      await repo.changes.close();
    },
  );
}
