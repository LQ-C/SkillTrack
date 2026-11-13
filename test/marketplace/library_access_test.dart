import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skilltrack/features/tutor_management/widgets/library_access_dialog.dart';
import 'tutor_management_test.dart' show MemoryTutors;

class AccessTutors extends MemoryTutors {
  bool granted = false;
  @override
  Future<bool> learnerLibraryAccess(String learnerId) async => granted;
  @override
  Future<void> setLearnerLibraryAccess(String learnerId, bool grant) async {
    granted = grant;
  }
}

void main() {
  for (final initial in [false, true]) {
    testWidgets(
      initial
          ? 'mentor revokes material access'
          : 'mentor grants material access',
      (tester) async {
        final repo = AccessTutors()..granted = initial;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showDialog<bool>(
                    context: context,
                    builder: (_) => LibraryAccessDialog(
                      repository: repo,
                      learnerId: 'student',
                      learnerName: 'Alex',
                    ),
                  ),
                  child: const Text('Manage'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Manage'));
        await tester.pumpAndSettle();
        await tester.tap(find.text(initial ? 'Revoke access' : 'Grant access'));
        await tester.pumpAndSettle();
        expect(repo.granted, !initial);
        expect(find.byType(LibraryAccessDialog), findsNothing);
      },
    );
  }
}
