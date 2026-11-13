import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skilltrack/app/app_theme.dart';
import 'package:skilltrack/features/authentication/models/auth_registration.dart';
import 'package:skilltrack/features/authentication/models/mentor_registration.dart';
import 'package:skilltrack/features/authentication/services/account_service.dart';
import 'package:skilltrack/features/authentication/views/auth_screen.dart';
import 'package:skilltrack/features/authentication/views/mentor_access_gate.dart';
import 'tutor_management_test.dart' show MemoryTutors, tutorProfile;

class RegistrationAccounts extends AccountService {
  String accountRole = 'mentor';
  int registrations = 0;
  MentorRegistration? application;
  @override
  Future<Map<String, dynamic>> loadProfile() async => {'role': accountRole};
  @override
  Future<AuthRegistration> register({
    required String email,
    required String password,
    required String name,
    required String birthDate,
    required String role,
    MentorRegistration? mentorApplication,
  }) async {
    registrations++;
    application = mentorApplication;
    return const AuthRegistration(verificationRequired: true);
  }
}

Future<void> chooseMentor(WidgetTester tester) async {
  await tester.tap(find.text('Create account'));
  await tester.pumpAndSettle();
  final role = find.byType(DropdownButtonFormField<String>);
  await tester.ensureVisible(role);
  await tester.pumpAndSettle();
  await tester.tap(role);
  await tester.pumpAndSettle();
  await tester.tap(find.text('Mentor').last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('mentor signup requires no credential or application', (
    tester,
  ) async {
    final accounts = RegistrationAccounts();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: AuthScreen(service: accounts),
      ),
    );
    await chooseMentor(tester);
    expect(find.text('Mentor verification'), findsNothing);
    expect(find.text('Upload credential'), findsNothing);
    Future<void> fill(String label, String value) async {
      final finder = find.widgetWithText(TextFormField, label);
      await tester.ensureVisible(finder);
      await tester.pumpAndSettle();
      await tester.enterText(finder, value);
    }

    await fill('Full name', 'New Mentor');
    tester
            .widget<TextFormField>(
              find.widgetWithText(TextFormField, 'Date of birth'),
            )
            .controller!
            .text =
        '2000-01-01';
    await fill('Email address', 'mentor@example.test');
    await fill('Password', 'StrongPass1!');
    await fill('Confirm password', 'StrongPass1!');
    await tester.ensureVisible(find.text('Create my account'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create my account'));
    await tester.pumpAndSettle();
    expect(accounts.registrations, 1);
    expect(accounts.application, isNull);
    expect(
      find.textContaining('Check your inbox for a verification link'),
      findsOneWidget,
    );
  });
  for (final role in ['student', 'mentor']) {
    for (final status in ['pending', 'rejected', 'unsubmitted']) {
      testWidgets('$role enters Home with $status profile and no credential', (
        tester,
      ) async {
        await tester.pumpWidget(
          MaterialApp(
            home: MentorAccessGate(
              accounts: RegistrationAccounts()..accountRole = role,
              tutors: MemoryTutors()..own = tutorProfile(status),
              child: const Text('Home'),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Home'), findsOneWidget);
        expect(find.textContaining('Awaiting credential'), findsNothing);
      });
    }
  }
}
