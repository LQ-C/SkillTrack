import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:skilltrack/features/tutor_management/views/demo_checkout_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skilltrack/app/app_theme.dart';
import 'package:skilltrack/features/tutor_management/models/mentor_payment.dart';
import 'package:skilltrack/features/tutor_management/models/tutor_models.dart';
import 'package:skilltrack/features/tutor_management/views/mentor_detail_screen.dart';
import 'package:skilltrack/features/tutor_management/views/mentor_payments_screen.dart';
import 'package:skilltrack/features/tutor_management/widgets/session_booking_dialog.dart';
import 'tutor_management_test.dart' show MemoryTutors, mentor;

class PaymentTutors extends MemoryTutors {
  int? savedAmount;
  int credits = 0;
  bool materials = false;
  final outcomes = <String>[];
  String? checkoutSlotId;
  @override
  Future<MentorPaymentOrder> prepareSessionPayment(String slotId) async {
    checkoutSlotId = slotId;
    return MentorPaymentOrder.fromJson({
      'id': 'session-payment',
      'mentor_id': 'mentor',
      'mentor_name': 'Mentor',
      'learner_name': 'Student',
      'status': 'pending',
      'amount': 300,
      'purchase_kind': 'session',
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  @override
  Future<void> completeDemoPayment(String orderId, String outcome) async {
    outcomes.add(outcome);
    if (outcome == 'success') credits++;
  }

  @override
  Future<MentorPaymentOffer?> paymentOffer(String mentorId) async =>
      const MentorPaymentOffer(5000);
  @override
  Future<MentorPaymentAccess> paymentAccess(String mentorId) async =>
      MentorPaymentAccess(materials: materials, credits: credits);
  @override
  Future<void> savePaymentOffer(int amount) async {
    savedAmount = amount;
  }

  @override
  Future<List<MentorSlot>> availableSlots(String mentorId) async {
    final start = DateTime.now().add(const Duration(days: 2));
    return [
      MentorSlot.fromJson({
        'id': 'slot',
        'starts_at': start.toIso8601String(),
        'ends_at': start.add(const Duration(hours: 1)).toIso8601String(),
      }),
    ];
  }
}

void main() {
  testWidgets('mentor sets an exact RM package price with validation', (
    tester,
  ) async {
    final repo = PaymentTutors();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: MentorPaymentsScreen(repository: repo),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Payment history for test transactions.'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField), '12.345');
    await tester.tap(find.text('Save materials price'));
    await tester.pumpAndSettle();
    expect(repo.savedAmount, isNull);
    await tester.enterText(find.byType(TextFormField), '12.30');
    await tester.tap(find.text('Save materials price'));
    await tester.pumpAndSettle();
    expect(repo.savedAmount, 1230);
  });
  testWidgets('student cannot change mentor package pricing', (tester) async {
    final repo = PaymentTutors()
      ..accountRole = 'student'
      ..userId = 'student';
    await tester.pumpWidget(
      MaterialApp(home: MentorPaymentsScreen(repository: repo)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Save materials price'), findsNothing);
    expect(find.byType(TextFormField), findsNothing);
  });
  for (final (materials, credits) in [(false, 0), (true, 0), (true, 1)]) {
    testWidgets('booking with materials=$materials and credits=$credits', (
      tester,
    ) async {
      final repo = PaymentTutors()
        ..accountRole = 'student'
        ..userId = 'student'
        ..materials = materials
        ..credits = credits;
      await tester.pumpWidget(
        MaterialApp(
          home: MentorDetailScreen(repository: repo, mentor: mentor()),
        ),
      );
      await tester.pumpAndSettle();
      final button = find.widgetWithText(
        OutlinedButton,
        credits == 0 ? 'Choose session · RM3.00' : 'Choose session time',
      );
      await tester.tap(find.text('Sessions'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        button,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<OutlinedButton>(button).onPressed,
        materials ? isNotNull : isNull,
      );
      if (!materials) return;
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.byType(SessionBookingDialog), findsOneWidget);
      if (credits == 0) {
        await tester.tap(find.text('Continue to pay RM3.00'));
        await tester.pumpAndSettle();
        expect(repo.checkoutSlotId, 'slot');
        expect(find.text('Mentoring session'), findsOneWidget);
      } else {
        expect(find.text('Confirm booking'), findsOneWidget);
        expect(repo.checkoutSlotId, isNull);
      }
    });
  }
  for (final method in [
    'Debit card',
    'Touch ’n Go eWallet',
    'Cancel payment',
  ]) {
    final outcome = method == 'Cancel payment' ? 'cancelled' : 'success';
    testWidgets('demo checkout handles $method without card details', (
      tester,
    ) async {
      final repo = PaymentTutors();
      final order = await repo.prepareDemoPayment('mentor');
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.push<bool>(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        DemoCheckoutScreen(repository: repo, order: order),
                  ),
                ),
                child: const Text('Open checkout'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open checkout'));
      await tester.pumpAndSettle();
      expect(find.text('Checkout'), findsOneWidget);
      expect(find.byType(TextFormField), findsNothing);
      final label = outcome == 'success' ? 'Pay ${order.price}' : method;
      if (outcome == 'success') {
        await tester.scrollUntilVisible(
          find.text(method),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text(method));
        await tester.pumpAndSettle();
      }
      if (method == 'Debit card') {
        for (final field in const [
          ('Card number', '9876543210123456'),
          ('Expiry (MM/YY)', '04/38'),
          ('CVC', '789'),
        ]) {
          final input = find.widgetWithText(TextFormField, field.$1);
          await tester.scrollUntilVisible(
            input,
            120,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.enterText(input, field.$2);
        }
      }
      await tester.scrollUntilVisible(
        find.text(label),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      if (method == 'Touch ’n Go eWallet') {
        expect(find.byType(QrImageView), findsOneWidget);
        expect(repo.outcomes, isEmpty);
        await tester.tap(find.text('Approve payment'));
        await tester.pumpAndSettle();
      }
      expect(repo.outcomes, [outcome]);
      expect(repo.credits, outcome == 'success' ? 1 : 0);
    });
  }
}
