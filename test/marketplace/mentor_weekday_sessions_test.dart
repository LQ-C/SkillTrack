import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:skilltrack/features/tutor_management/widgets/session_booking_dialog.dart';
import 'package:skilltrack/features/tutor_management/models/tutor_models.dart';
import 'package:skilltrack/features/tutor_management/views/mentor_detail_screen.dart';

MentorSlot slot(String id, DateTime start) => MentorSlot.fromJson({
  'id': id,
  'starts_at': start.toIso8601String(),
  'ends_at': start.add(const Duration(hours: 1)).toIso8601String(),
});

void main() {
  test('shows weekdays once and keeps the earliest actual booking slot', () {
    final monday = DateTime(2026, 11, 9, 9);
    final sessions = [
      slot('later-monday', monday.add(const Duration(days: 7))),
      slot('tuesday', monday.add(const Duration(days: 1))),
      slot('later-tuesday', monday.add(const Duration(days: 8))),
      slot('monday', monday),
      slot('same-day-later', monday.add(const Duration(hours: 2))),
    ];
    expect(earliestSessionPerWeekday(sessions).map((s) => s.id), [
      'monday',
      'tuesday',
    ]);
    expect(sessions.length, 5);
  });

  test(
    'moves to the following week when the earlier session is unavailable',
    () {
      final next = slot('next-monday', DateTime(2026, 11, 16, 9));
      expect(earliestSessionPerWeekday([next]).single, same(next));
      expect(earliestSessionPerWeekday([]), isEmpty);
    },
  );
  testWidgets('shows the mentor’s hours and books the selected slot', (
    tester,
  ) async {
    MentorSlot malaysiaSlot(String id, DateTime start) => MentorSlot.fromJson({
      'id': id,
      'starts_at': start.toIso8601String(),
      'ends_at': start.add(const Duration(hours: 1)).toIso8601String(),
      'utc_offset_minutes': 480,
      'window_start': 6 * 60,
      'window_end': 12 * 60,
    });
    final first = malaysiaSlot('seven', DateTime.utc(2026, 11, 8, 23));
    final second = malaysiaSlot('eight', DateTime.utc(2026, 11, 9));
    expect(nearestWeekdayOptions([first, second]).single, [first, second]);
    MentorSlot? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await showDialog<MentorSlot>(
                  context: context,
                  builder: (_) =>
                      SessionBookingDialog(sessions: [first, second]),
                );
              },
              child: Text(weekdaySessionTime(context, first, last: second)),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Monday · 6:00 AM–12:00 PM'));
    await tester.pumpAndSettle();
    expect(find.textContaining('November 9, 2026'), findsOneWidget);
    await tester.tap(find.byType(DropdownButtonFormField<MentorSlot>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('8:00 AM–9:00 AM').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm booking'));
    await tester.pumpAndSettle();
    expect(result?.id, 'eight');
  });
}
