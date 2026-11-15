import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skilltrack/app/app_theme.dart';
import 'package:skilltrack/features/kanban/widgets/milestone_progress_section.dart';
import 'package:skilltrack/features/kanban/viewmodels/kanban_view_model.dart';
import 'package:skilltrack/features/projects/models/project_milestone.dart';
import '../fake_repository.dart';

class Milestones extends KanbanViewModel {
  Milestones(this.count) : super(FakeKanbanRepository());
  final int count;
  int completed = 1;
  @override
  List<ProjectMilestone> get availableMilestones => [
    for (var i = 0; i < count; i++)
      ProjectMilestone(
        id: '$i',
        projectId: 'p',
        position: i,
        title: i == 0
            ? 'Authentication'
            : 'Milestone $i with a long name that wraps on small screens',
      ),
  ];
  @override
  ({int completed, int total}) milestoneProgress(String id) =>
      id == '0' ? (completed: completed, total: 2) : (completed: 0, total: 0);
}

void main() {
  testWidgets(
    'toggle preserves surrounding horizontal and vertical scroll offsets',
    (tester) async {
      final model = Milestones(2);
      addTearDown(model.dispose);
      final horizontal = ScrollController();
      final vertical = ScrollController();
      addTearDown(horizontal.dispose);
      addTearDown(vertical.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                MilestoneProgressSection(viewModel: model),
                Expanded(
                  child: SingleChildScrollView(
                    controller: horizontal,
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      width: 1200,
                      child: ListView(
                        controller: vertical,
                        children: [
                          for (var i = 0; i < 40; i++)
                            SizedBox(height: 70, child: Text('Task $i')),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      horizontal.jumpTo(100);
      vertical.jumpTo(250);
      await tester.pump();
      await tester.tap(find.text('Milestones · 2'));
      await tester.pumpAndSettle();
      expect(horizontal.offset, 100);
      expect(vertical.offset, 250);
      await tester.tap(find.text('Milestones · 2'));
      await tester.pumpAndSettle();
      expect(horizontal.offset, 100);
      expect(vertical.offset, 250);
    },
  );

  testWidgets(
    'header toggles summary and animates live progress without completing empty milestones',
    (tester) async {
      final model = Milestones(2);
      addTearDown(model.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(body: MilestoneProgressSection(viewModel: model)),
        ),
      );
      expect(find.text('Milestones · 2'), findsOneWidget);
      expect(find.text('0 of 2 milestones completed'), findsOneWidget);
      expect(find.text('Authentication'), findsNothing);
      await tester.tap(find.text('Milestones · 2'));
      await tester.pumpAndSettle();
      expect(find.text('1/2 tasks'), findsOneWidget);
      expect(find.text('50%'), findsOneWidget);
      expect(find.text('0/0 tasks · No tasks'), findsOneWidget);
      model.completed = 2;
      model.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('100%'), findsOneWidget);
      expect(find.text('1 of 2 milestones completed'), findsOneWidget);
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
      await tester.tap(find.text('Milestones · 2'));
      await tester.pumpAndSettle();
      expect(find.text('Authentication'), findsNothing);
    },
  );
  testWidgets(
    'empty milestones show a safe empty state and respect reduced motion',
    (tester) async {
      final model = Milestones(0);
      addTearDown(model.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: Scaffold(body: MilestoneProgressSection(viewModel: model)),
          ),
        ),
      );
      expect(
        tester
            .widget<ExpansionTile>(find.byType(ExpansionTile))
            .expansionAnimationStyle!
            .duration,
        Duration.zero,
      );
      await tester.tap(find.text('Milestones · 0'));
      await tester.pumpAndSettle();
      expect(find.text('No milestones yet.'), findsOneWidget);
      expect(find.text('0 of 0 milestones completed'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'long list is bounded, wraps at large text and scrolls internally',
    (tester) async {
      tester.view.physicalSize = const Size(320, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final model = Milestones(30);
      addTearDown(model.dispose);
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
            body: Column(
              children: [
                MilestoneProgressSection(viewModel: model),
                const Expanded(child: Text('Board')),
              ],
            ),
          ),
        ),
      );
      await tester.tap(find.text('Milestones · 30'));
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byType(ListView)).height,
        lessThanOrEqualTo(160),
      );
      await tester.scrollUntilVisible(
        find.text('Milestone 29 with a long name that wraps on small screens'),
        150,
        scrollable: find.byType(Scrollable).last,
        maxScrolls: 150,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
