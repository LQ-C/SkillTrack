import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skilltrack/features/dashboard/widgets/project_carousel.dart';
import 'package:skilltrack/features/projects/models/project_with_progress.dart';
import 'package:skilltrack/features/projects/models/learning_project.dart';

ProjectWithProgress item(String id) => ProjectWithProgress(
  project: LearningProject(
    id: id,
    ownerId: 'u',
    name: 'Project $id with a long descriptive title that wraps',
    status: 'active',
    endDate: DateTime(2026, 12, 1),
  ),
  boardId: id,
  totalTaskCount: 4,
  completedTaskCount: 1,
  stalledTaskCount: 2,
);
void main() {
  testWidgets('swipes, retains selection through refresh and handles removal', (
    tester,
  ) async {
    String? opened;
    Widget build(List<String> ids) => MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ProjectCarousel(
            projects: ids.map(item).toList(),
            onOpen: (p) => opened = p.project.id,
          ),
        ),
      ),
    );
    await tester.pumpWidget(build(['a', 'b', 'c']));
    await tester.pumpAndSettle();
    expect(find.text('Project 1 of 3'), findsOneWidget);
    await tester.drag(find.byType(PageView), const Offset(-650, 0));
    await tester.pumpAndSettle();
    expect(find.text('Project 2 of 3'), findsOneWidget);
    await tester.pumpWidget(build(['a', 'b', 'c']));
    await tester.pumpAndSettle();
    expect(find.text('Project 2 of 3'), findsOneWidget);
    await tester.pumpWidget(build(['b', 'c']));
    await tester.pumpAndSettle();
    expect(find.text('Project 1 of 2'), findsOneWidget);
    await tester.tap(find.text(item('b').project.name));
    expect(opened, 'b');
    await tester.pumpWidget(build(['c']));
    await tester.pumpAndSettle();
    expect(find.text('Project 1 of 1'), findsNothing);
    expect(find.text(item('c').project.name), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'narrow large text fits and vertical scroll coexists with swipes',
    (tester) async {
      tester.view.physicalSize = const Size(320, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2.4)),
            child: child!,
          ),
          home: Scaffold(
            body: ListView(
              children: [
                ProjectCarousel(
                  projects: [item('a'), item('b')],
                  onOpen: (_) {},
                ),
                const SizedBox(height: 800),
                const Text('End'),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.drag(find.byType(PageView), const Offset(-280, 0));
      await tester.pumpAndSettle();
      expect(find.text('Project 2 of 2'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.text('End'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
    },
  );
}
