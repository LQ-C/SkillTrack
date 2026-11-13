import 'dart:async';
import 'dart:typed_data';
import 'package:skilltrack/features/tutor_management/models/mentor_payment.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skilltrack/app/app_theme.dart';
import 'package:skilltrack/features/tutor_management/models/tutor_models.dart';
import 'package:skilltrack/features/tutor_management/repositories/tutor_repository.dart';
import 'package:skilltrack/features/tutor_management/viewmodels/tutor_view_model.dart';
import 'package:skilltrack/features/tutor_management/views/mentorship_screen.dart';
import 'package:skilltrack/features/tutor_management/widgets/tutor_forms.dart';
import 'package:skilltrack/features/tutor_management/utils/qualification_file.dart';

TutorProfile tutorProfile(String status, {String qualificationPath = ''}) =>
    TutorProfile.fromJson({
      'headline': 'Programming',
      'expertise': 'Programming',
      'experience': 'Five years building mobile applications.',
      'credential_url': '',
      'qualification_path': qualificationPath,
      'teaching_preferences': 'Online, beginner-friendly sessions.',
      'verification_status': status,
      'review_note': '',
    });
Mentor mentor() => Mentor.fromJson({
  'user_id': 'mentor',
  'full_name': 'Mentor Name',
  'headline': 'Flutter mentor',
  'expertise': 'Programming',
  'teaching_preferences': 'Online',
  'average_rating': 4.5,
  'review_count': 2,
});

class MemoryTutors implements TutorRepository {
  @override
  String userId = 'mentor';
  @override
  Future<MentorPaymentOffer?> paymentOffer(String mentorId) async => null;
  @override
  Future<MentorPaymentAccess> paymentAccess(String mentorId) async =>
      const MentorPaymentAccess();
  @override
  Future<List<MentorPaymentOrder>> paymentOrders() async => [];
  @override
  Future<void> savePaymentOffer(int amount) async {}
  @override
  Future<MentorPaymentOrder> prepareDemoPayment(String mentorId) async =>
      MentorPaymentOrder.fromJson({
        'id': 'demo',
        'mentor_id': mentorId,
        'mentor_name': 'Mentor',
        'learner_name': 'Student',
        'amount': 5000,
        'status': 'pending',
        'created_at': DateTime.now().toIso8601String(),
      });
  @override
  Future<void> completeDemoPayment(String orderId, String outcome) async {}
  @override
  Future<MentorPaymentOrder> prepareSessionPayment(String slotId) async =>
      throw UnimplementedError();
  @override
  Future<void> refreshPayments() async {}

  String accountRole = 'mentor';
  int directoryReads = 0;
  String? savedQualification;
  @override
  Future<String> role() async => accountRole;
  @override
  Future<String> uploadQualification(Uint8List bytes, String fileName) async =>
      'mentor/degree.pdf';
  @override
  Future<void> removeQualification(String path) async {}
  TutorProfile? own;
  bool fail = false;
  bool submitted = false;
  Completer<void>? pending;
  @override
  Future<TutorProfile?> profile() async {
    if (fail) throw Exception('secret backend detail');
    return own;
  }

  @override
  Future<List<Mentor>> directory() async {
    directoryReads++;
    return [mentor()];
  }

  @override
  Future<List<MentorSlot>> slots(String mentorId) async => [];
  @override
  Future<List<MentorSlot>> availableSlots(String mentorId) async => [];
  @override
  Future<List<MentorshipSession>> sessions() async => [];
  @override
  Future<List<MentorFeedback>> feedback(String mentorId) async => [];
  @override
  Future<void> enable() async {
    await pending?.future;
    own = profileData();
  }

  TutorProfile profileData() => tutorProfile('unsubmitted');
  @override
  Future<void> publishWithSchedule({
    required String headline,
    required String expertise,
    required String experience,
    required String credentialUrl,
    required String preferences,
    required List<WeeklyAvailability> availability,
    required int utcOffsetMinutes,
  }) async {
    submitted = true;
    savedQualification = '';
  }

  @override
  Future<void> saveProfile({
    required String headline,
    required String expertise,
    required String experience,
    required String credentialUrl,
    required String qualificationPath,
    required String preferences,
    required bool submit,
  }) async {
    submitted = submit;
    savedQualification = qualificationPath;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('qualification validation checks file signatures and size', () {
    expect(
      qualificationMime(Uint8List.fromList([37, 80, 68, 70, 45]), 'degree.pdf'),
      'application/pdf',
    );
    expect(
      () => qualificationMime(Uint8List.fromList([1, 2, 3]), 'degree.pdf'),
      throwsFormatException,
    );
    expect(
      () => qualificationMime(
        Uint8List.fromList([37, 80, 68, 70, 45]),
        'degree.exe',
      ),
      throwsFormatException,
    );
    expect(
      () => qualificationMime(Uint8List(0), 'degree.pdf'),
      throwsFormatException,
    );
    expect(
      () =>
          qualificationMime(Uint8List(maxQualificationBytes + 1), 'degree.pdf'),
      throwsFormatException,
    );
  });
  testWidgets('student can find mentors and has no mentor workspace', (
    tester,
  ) async {
    final repo = MemoryTutors()..accountRole = 'student';
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: MentorshipScreen(repository: repo),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Find mentors'), findsOneWidget);
    expect(find.text('My mentoring'), findsNothing);
    expect(find.text('Mentor Name'), findsOneWidget);
    expect(repo.directoryReads, 1);
  });
  testWidgets(
    'mentor saves teaching profile without uploading a qualification',
    (tester) async {
      final repo = MemoryTutors();
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: TutorProfileEditor(
            repository: repo,
            profile: tutorProfile('unsubmitted'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Upload qualification'), findsNothing);
      expect(find.text('Session duration'), findsNothing);
      await tester.ensureVisible(find.text('Monday'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(SwitchListTile, 'Monday'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Publish profile to Explore'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Publish profile to Explore'));
      await tester.pumpAndSettle();
      expect(repo.submitted, isTrue);
      expect(repo.savedQualification, '');
    },
  );
  testWidgets('publishing requires a selected free day', (tester) async {
    final repo = MemoryTutors();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: TutorProfileEditor(
          repository: repo,
          profile: tutorProfile('approved'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Publish profile to Explore'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Publish profile to Explore'));
    await tester.pumpAndSettle();
    expect(repo.submitted, isFalse);
    expect(find.text('Select at least one day you are free.'), findsOneWidget);
  });
  test('failed loads protect exception details and support retry', () async {
    final repo = MemoryTutors()..fail = true;
    final vm = TutorViewModel(repo);
    await vm.load();
    expect(vm.error, isNotNull);
    expect(vm.error, isNot(contains('secret')));
    repo.fail = false;
    await vm.load();
    expect(vm.error, isNull);
    expect(vm.loading, isFalse);
    vm.dispose();
  });
  test('duplicate mentor activation is ignored and disposal is safe', () async {
    final repo = MemoryTutors()..pending = Completer<void>();
    final vm = TutorViewModel(repo);
    var calls = 0;
    final work = vm.action(() {
      calls++;
      return repo.enable();
    }, 'Enabled');
    expect(
      await vm.action(() async {
        calls++;
      }, 'Duplicate'),
      isFalse,
    );
    expect(calls, 1);
    vm.dispose();
    repo.pending!.complete();
    await work;
  });
  testWidgets('mentor activates teaching without finding other mentors', (
    tester,
  ) async {
    final repo = MemoryTutors();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: MentorshipScreen(repository: repo),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('My mentoring'));
    await tester.pumpAndSettle();
    expect(find.text('Find mentors'), findsNothing);
    expect(repo.directoryReads, 0);
    await tester.tap(find.text('Create mentor profile'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Verification:'), findsNothing);
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Add availability'),
    );
    expect(button.onPressed, isNotNull);
  });
  testWidgets(
    'approved mentor can offer availability and sees real feedback empty state',
    (tester) async {
      final repo = MemoryTutors()
        ..own = tutorProfile(
          'approved',
          qualificationPath: 'mentor/degree.pdf',
        );
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: MentorshipScreen(repository: repo),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('My mentoring'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Add availability'),
            )
            .onPressed,
        isNotNull,
      );
      await tester.ensureVisible(find.text('Your performance'));
      await tester.pumpAndSettle();
      expect(find.text('No reviews yet.'), findsOneWidget);
      await tester.ensureVisible(find.text('Add availability'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add availability'));
      await tester.pumpAndSettle();
      expect(find.text('Choose date and time'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('pending mentor with no qualification can offer teaching slots', (
    tester,
  ) async {
    final repo = MemoryTutors()..own = tutorProfile('pending');
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: MentorshipScreen(repository: repo),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Add availability'),
          )
          .onPressed,
      isNotNull,
    );
    expect(find.textContaining('awaiting administrator'), findsNothing);
  });
  testWidgets('mentor workspace fits a narrow phone with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.5)),
          child: child!,
        ),
        home: MentorshipScreen(
          repository: MemoryTutors()..own = tutorProfile('pending'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('My mentoring'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('My mentoring'));
    await tester.pumpAndSettle();
    expect(find.text('Your mentor workspace'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
