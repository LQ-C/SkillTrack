import 'package:skilltrack/features/tutor_management/models/mentor_payment.dart';
import 'package:skilltrack/features/tutor_management/views/demo_checkout_screen.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skilltrack/features/educational_content/repositories/content_repository.dart';
import 'package:skilltrack/features/educational_content/models/learning_resource.dart';
import 'package:skilltrack/features/tutor_management/views/mentor_detail_screen.dart';
import 'package:skilltrack/features/tutor_management/viewmodels/mentor_detail_view_model.dart';
import 'package:skilltrack/features/tutor_management/repositories/tutor_repository.dart';
import 'content_test.dart' show FakeContentRepository, sample;
import 'mentor_payments_test.dart' show PaymentTutors;
import 'tutor_management_test.dart' show mentor;

class Previews extends FakeContentRepository
    implements MentorResourcePreviewRepository {
  int previewCalls = 0, fullReads = 0;
  bool hidden = false, deleted = false;
  Completer<List<LearningResource>>? pending;
  @override
  Future<List<LearningResource>> mentorPreviews(
    String mentorId, {
    required int offset,
  }) async {
    previewCalls++;
    if (pending != null) return pending!.future;
    if (this.fail) throw StateError('offline');
    return empty
        ? []
        : [
            LearningResource(
              id: sample.id,
              authorId: sample.authorId,
              authorName: sample.authorName,
              title: sample.title,
              summary: sample.summary,
              category: sample.category,
              level: sample.level,
              kind: sample.kind,
              body: '',
              link: '',
              tags: [],
              status: 'published',
            ),
          ];
  }

  @override
  Future<LearningResource> get(String id) async {
    fullReads++;
    if (deleted) throw StateError('gone');
    return LearningResource(
      id: sample.id,
      authorId: sample.authorId,
      authorName: sample.authorName,
      title: sample.title,
      summary: sample.summary,
      category: sample.category,
      level: sample.level,
      kind: sample.kind,
      body: sample.body,
      link: sample.link,
      tags: [],
      status: 'published',
      hidden: hidden,
    );
  }
}

class AccountTutors extends PaymentTutors implements TutorSessionSource {
  final changes = StreamController<String?>.broadcast(sync: true);
  @override
  Stream<String?> get userChanges => changes.stream;
}

class CheckoutTutors extends PaymentTutors {
  int prepared = 0;
  @override
  Future<MentorPaymentOrder> prepareDemoPayment(String mentorId) async {
    prepared++;
    return super.prepareDemoPayment(mentorId);
  }

  @override
  Future<void> completeDemoPayment(String id, String outcome) async {
    if (outcome == 'success') materials = true;
  }
}

void main() {
  test(
    'deduplicates loading and rejects revoked, hidden, deleted and stale resources',
    () async {
      final tutors = AccountTutors()
        ..userId = 'student'
        ..accountRole = 'student'
        ..materials = true;
      final content = Previews();
      final vm = MentorDetailViewModel(tutors, 'mentor', content);
      await Future.wait([vm.load(), vm.load()]);
      expect(content.previewCalls, 1);
      expect(content.fullReads, 0);
      expect(await vm.canOpen('one'), true);
      tutors.materials = false;
      expect(await vm.canOpen('one'), false);
      expect(content.fullReads, 1);
      tutors.materials = true;
      content.hidden = true;
      expect(await vm.canOpen('one'), false);
      content.deleted = true;
      await expectLater(vm.canOpen('one'), throwsStateError);
      tutors.userId = 'other';
      tutors.changes.add('other');
      expect(vm.current, false);
      expect(vm.resources, isEmpty);
      vm.dispose();
      await tutors.changes.close();
    },
  );
  test(
    'empty and failed material requests stay distinct and disposal ignores response',
    () async {
      final tutors = PaymentTutors()
        ..userId = 'student'
        ..accountRole = 'student';
      final content = Previews()..empty = true;
      final vm = MentorDetailViewModel(tutors, 'mentor', content);
      await vm.load();
      expect(vm.resources, isEmpty);
      expect(vm.materialsError, isNull);
      content.fail = true;
      await vm.load();
      expect(vm.materialsError, isNotNull);
      expect(vm.slots, isNotEmpty);
      content.fail = false;
      content.pending = Completer();
      final pending = vm.loadMaterials();
      vm.dispose();
      content.pending!.complete([sample]);
      await pending;
      expect(vm.resources, isEmpty);
    },
  );
  for (final paid in [false, true]) {
    testWidgets('material cards paid=$paid and tab switching retains data', (
      tester,
    ) async {
      final tutors = PaymentTutors()
        ..userId = 'student'
        ..accountRole = 'student'
        ..materials = paid;
      final content = Previews();
      final routes = <RouteSettings>[];
      await tester.pumpWidget(
        MaterialApp(
          onGenerateRoute: (s) {
            routes.add(s);
            return MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Text('Viewer')),
            );
          },
          home: MentorDetailScreen(
            repository: tutors,
            mentor: mentor(),
            content: content,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final action = find.text(paid ? 'View details' : 'Unlock Materials');
      await tester.scrollUntilVisible(
        action,
        150,
        scrollable: find.byWidgetPredicate(
          (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
        ),
      );
      expect(find.text(sample.body), findsNothing);
      expect(content.fullReads, 0);
      expect(content.previewCalls, 1);
      if (paid) {
        await tester.tap(action);
        await tester.pumpAndSettle();
        expect(routes.last.name, '/resources/details');
        expect(routes.last.arguments, 'one');
      } else {
        expect(find.textContaining('RM50.00'), findsOneWidget);
      }
    });
  }
  testWidgets(
    'checkout return refreshes access and duplicate unlock taps open once',
    (tester) async {
      final tutors = CheckoutTutors()
        ..userId = 'student'
        ..accountRole = 'student';
      final content = Previews();
      await tester.pumpWidget(
        MaterialApp(
          home: MentorDetailScreen(
            repository: tutors,
            mentor: mentor(),
            content: content,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Unlock Materials').hitTestable(),
        150,
        scrollable: find.byWidgetPredicate(
          (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
        ),
      );
      await tester.tap(find.text('Unlock Materials'));
      await tester.tap(find.text('Unlock Materials'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(tutors.prepared, 1);
      expect(find.byType(DemoCheckoutScreen), findsOneWidget);
      await tutors.completeDemoPayment('demo', 'success');
      tester.state<NavigatorState>(find.byType(Navigator)).pop(true);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('View details'),
        150,
        scrollable: find.byWidgetPredicate(
          (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
        ),
      );
      expect(find.text('Unlock Materials'), findsNothing);
      expect(content.fullReads, 0);
    },
  );
  testWidgets(
    'switching tabs keeps loaded previews and booking tap opens one dialog',
    (tester) async {
      final tutors = PaymentTutors()
        ..userId = 'student'
        ..accountRole = 'student'
        ..materials = true;
      final content = Previews();
      await tester.pumpWidget(
        MaterialApp(
          home: MentorDetailScreen(
            repository: tutors,
            mentor: mentor(),
            content: content,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sessions'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Choose session · RM3.00'),
        150,
        scrollable: find.byWidgetPredicate(
          (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
        ),
      );
      await tester.tap(find.text('Choose session · RM3.00'));
      await tester.tap(
        find.text('Choose session · RM3.00'),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Learning Materials'),
        -200,
        scrollable: find.byWidgetPredicate(
          (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
        ),
      );
      await tester.tap(find.text('Learning Materials'));
      await tester.pumpAndSettle();
      expect(content.previewCalls, 1);
    },
  );
  testWidgets(
    'own profile has read controls without purchase and fits large text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final tutors = PaymentTutors()
        ..userId = 'mentor'
        ..accountRole = 'mentor';
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.8)),
            child: child!,
          ),
          home: MentorDetailScreen(
            repository: tutors,
            mentor: mentor(),
            content: Previews(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('View details'),
        200,
        scrollable: find.byWidgetPredicate(
          (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
        ),
      );
      expect(find.text('Unlock Materials'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
