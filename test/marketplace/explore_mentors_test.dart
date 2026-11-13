import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skilltrack/features/dashboard/views/home_screen.dart';
import 'package:skilltrack/features/tutor_management/views/explore_mentors_screen.dart';
import 'package:skilltrack/features/tutor_management/views/mentor_detail_screen.dart';
import 'tutor_management_test.dart' show MemoryTutors, tutorProfile;
import 'package:skilltrack/features/tutor_management/widgets/tutor_forms.dart';

void main() {
  for (final role in ['student', 'mentor']) {
    testWidgets('Explore navigation respects $role role', (tester) async {
      var opened = false;
      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(
            loadProfile: () async => {'full_name': 'Alex', 'role': role},
            onProfile: () async {},
            onLibrary: (_) async {},
            onExplore: () async {
              opened = true;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Explore'), findsOneWidget);
      {
        await tester.tap(find.text('Explore'));
        await tester.pumpAndSettle();
        expect(opened, isTrue);
      }
    });
  }

  testWidgets('students search mentors and open booking profile', (
    tester,
  ) async {
    final repository = MemoryTutors()
      ..accountRole = 'student'
      ..userId = 'student';
    await tester.pumpWidget(
      MaterialApp(home: ExploreMentorsScreen(repository: repository)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Mentor Name'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'cloud');
    await tester.pumpAndSettle();
    expect(find.text('Mentor Name'), findsNothing);
    await tester.enterText(find.byType(TextField), 'programming');
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('View profile & sessions'));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView).first, const Offset(0, -300));
    await tester.pumpAndSettle();
    await tester.tap(find.text('View profile & sessions'));
    await tester.pumpAndSettle();
    expect(find.byType(MentorDetailScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mentor cannot load the directory from Explore', (tester) async {
    final repository = MemoryTutors();
    await tester.pumpWidget(
      MaterialApp(home: ExploreMentorsScreen(repository: repository)),
    );
    await tester.pumpAndSettle();
    expect(repository.directoryReads, 0);
    expect(find.text('Mentor Name'), findsNothing);
  });
  testWidgets(
    'only mentor sees publication and can open their profile editor',
    (tester) async {
      final repository = MemoryTutors()..own = tutorProfile('approved');
      await tester.pumpWidget(
        MaterialApp(home: ExploreMentorsScreen(repository: repository)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Publish my mentor profile'), findsOneWidget);
      expect(find.text('Search names or skills'), findsNothing);
      await tester.ensureVisible(find.text('Publish my mentor profile'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Publish my mentor profile'));
      await tester.pumpAndSettle();
      expect(find.byType(TutorProfileEditor), findsOneWidget);
      expect(repository.directoryReads, 0);
    },
  );
  testWidgets('student cannot publish a mentor profile', (tester) async {
    final repository = MemoryTutors()..accountRole = 'student';
    await tester.pumpWidget(
      MaterialApp(home: ExploreMentorsScreen(repository: repository)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Publish my mentor profile'), findsNothing);
    expect(find.text('Search names or skills'), findsOneWidget);
  });
}
