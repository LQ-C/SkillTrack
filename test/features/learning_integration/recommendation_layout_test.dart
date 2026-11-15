import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skilltrack/app/app_theme.dart';
import 'package:skilltrack/features/learning_integration/widgets/task_recommendations_section.dart';
import 'package:skilltrack/features/learning_integration/widgets/saved_resources_section.dart';
import 'package:skilltrack/features/learning_integration/view_models/task_bookmarks_view_model.dart';
import 'package:skilltrack/features/learning_integration/models/resource_recommendation.dart';
import 'task_recommendations_test.dart' show fixture, recommendation;
import 'task_bookmarks_test.dart' show FakeBookmarks;

void main() {
  testWidgets(
    'compact cards retain results during refresh, prevent duplicates and recover',
    (tester) async {
      final f = await fixture(stalled: false);
      await f.model.getRecommendations();
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
      await tester.pumpAndSettle();
      expect(find.text('Resources to help with this task'), findsOneWidget);
      final description = tester.widget<Text>(
        find.text(recommendation.summary),
      );
      expect(description.maxLines, 2);
      expect(description.overflow, TextOverflow.ellipsis);
      f.repo.pending = Completer();
      final calls = f.repo.calls;
      final refresh = tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (w) => w is IconButton && w.tooltip == 'Refresh recommendations',
            ),
          )
          .onPressed!;
      refresh();
      refresh();
      await tester.pump();
      expect(f.repo.calls, calls + 1);
      expect(find.text(recommendation.title), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      f.repo.pending!.completeError(StateError('offline'));
      await tester.pumpAndSettle();
      expect(find.text(recommendation.title), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      f.repo.pending = null;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(f.model.errorMessage, isNull);
    },
  );
  testWidgets(
    'bookmark state and task feedback update without changing saved section',
    (tester) async {
      final f = await fixture(stalled: false);
      await f.model.getRecommendations();
      final repo = FakeBookmarks();
      final bookmarks = TaskBookmarksViewModel(repo, 't');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: [
                  TaskRecommendationsSection(
                    viewModel: f.model,
                    bookmarks: bookmarks,
                  ),
                  SavedResourcesSection(model: bookmarks),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Save resource to task'));
      await tester.pumpAndSettle();
      expect(bookmarks.contains(recommendation.resourceId), true);
      expect(find.text('Saved to this task'), findsOneWidget);
      expect(find.byIcon(Icons.bookmark), findsWidgets);
      expect(find.text('Saved resources'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      bookmarks.dispose();
      await repo.changes.close();
    },
  );
  testWidgets(
    'View resource uses existing resource detail route and blocks duplicate navigation',
    (tester) async {
      final f = await fixture(stalled: false);
      await f.model.getRecommendations();
      final routes = <RouteSettings>[];
      await tester.pumpWidget(
        MaterialApp(
          onGenerateRoute: (s) {
            routes.add(s);
            return MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Text('Resource viewer')),
            );
          },
          home: Scaffold(body: TaskRecommendationsSection(viewModel: f.model)),
        ),
      );
      await tester.pumpAndSettle();
      final open = tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'View resource'))
          .onPressed!;
      open();
      open();
      await tester.pumpAndSettle();
      expect(routes.length, 1);
      expect(routes.single.name, '/resources/details');
      expect(routes.single.arguments, recommendation.resourceId);
    },
  );
  testWidgets('long titles and summaries fit small screen with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final f = await fixture(stalled: false);
    f.repo.items = [
      const ResourceRecommendation(
        resourceId: 'r',
        title:
            'A very long learning resource title with many words about software development and practical examples',
        summary:
            'A very long summary repeated to exercise wrapping and ellipsis without requiring any protected content download from storage.',
        type: 'Reading',
      ),
    ];
    await f.model.getRecommendations();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            child: TaskRecommendationsSection(viewModel: f.model),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
