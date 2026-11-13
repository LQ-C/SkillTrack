import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:skilltrack/app/views/setup_screen.dart';
import 'package:skilltrack/features/authentication/views/auth_screen.dart';
import 'package:skilltrack/features/profile/widgets/security_dialog.dart';
import 'package:skilltrack/features/authentication/services/account_service.dart';
import 'package:skilltrack/core/utils/validation.dart';

void main() {
  test(
    'password policy rejects missing character groups and excessive length',
    () {
      for (final password in [
        'short',
        'onlylowercase1!',
        'ONLYUPPERCASE1!',
        'NoNumbers!',
        'NoSymbols123',
        'Aa1!${'x' * 125}',
      ]) {
        expect(validatePassword(password), isNotNull);
      }
      expect(validatePassword('StrongPass1!'), isNull);
    },
  );

  test('names support international characters and reject markup', () {
    expect(validateName('Liau Tshin Vui'), isNull);
    expect(validateName('李明'), isNull);
    expect(validateName("Nur A'isyah"), isNull);
    expect(validateName('<script>'), isNotNull);
    expect(validateName('User123'), isNotNull);
  });

  test('birth dates reject future and calendar overflow dates', () {
    expect(validateBirthDate('2004-02-29'), isNull);
    expect(validateBirthDate('2003-02-29'), isNotNull);
    expect(validateBirthDate('2999-01-01'), isNotNull);
    expect(validateBirthDate(''), isNotNull);
  });

  testWidgets('missing configuration shows setup, not a working account', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: SetupScreen(message: 'Configure Supabase first.')),
    );
    expect(find.text('Connect your account service'), findsOneWidget);
    expect(find.text('Sign in'), findsNothing);
    expect(find.textContaining('No account has been created'), findsOneWidget);
  });

  testWidgets('sign in validates before making requests', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: AuthScreen(service: AccountService())),
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pump();
    expect(find.text('Enter a valid email address.'), findsOneWidget);
    expect(find.text('Enter your password.'), findsOneWidget);
  });

  testWidgets(
    'registration exposes required profile fields and password confirmation',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: AuthScreen(service: AccountService())),
      );
      await tester.tap(find.text('Create account'));
      await tester.pumpAndSettle();
      expect(find.text('Full name'), findsOneWidget);
      expect(find.text('Date of birth'), findsOneWidget);
      expect(find.text('Confirm password'), findsOneWidget);
    },
  );

  testWidgets('account deletion is explicitly confirmed with a password', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => const SecurityDialog(delete: true),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete permanently'));
    await tester.pump();
    expect(find.text('Enter your current password.'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Delete permanently'), findsNothing);
  });
}
