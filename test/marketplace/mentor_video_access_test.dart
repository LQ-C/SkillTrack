import 'package:skilltrack/features/tutor_management/models/mentor_payment.dart';
import 'package:skilltrack/features/tutor_management/views/demo_checkout_screen.dart';
import 'package:flutter/material.dart';
import 'package:skilltrack/features/tutor_management/views/mentor_detail_screen.dart';
import 'package:skilltrack/features/educational_content/widgets/uploaded_video_player.dart';
import 'tutor_management_test.dart' show mentor;
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:skilltrack/features/educational_content/models/learning_resource.dart';
import 'package:skilltrack/features/educational_content/repositories/content_repository.dart';
import 'package:skilltrack/features/tutor_management/viewmodels/mentor_detail_view_model.dart';
import 'mentor_detail_test.dart' show Previews, AccountTutors;

class VideoContent extends Previews implements ResourceOpeningRepository {
  @override
  bool isImageFile(LearningResource resource) => false;
  int urls = 0;
  Completer<String>? pendingUrl;
  @override
  Future<LearningResource> get(String id) async {
    if (deleted) throw StateError('deleted');
    return LearningResource(
      id: id,
      authorId: 'mentor',
      authorName: 'Mentor',
      title: 'Video',
      summary: 'Preview',
      category: 'Coding',
      level: 'Beginner',
      kind: 'Video',
      body: '',
      link:
          'https://fixture.invalid/storage/v1/object/authenticated/mentor-video-files/mentor/test.mp4',
      tags: [],
      status: 'published',
      hidden: hidden,
    );
  }

  @override
  Future<String> primaryFileUrl(LearningResource r) async {
    urls++;
    return pendingUrl == null
        ? 'https://fixture.invalid/signed/$urls.mp4'
        : pendingUrl!.future;
  }
}

class TwoVideos extends VideoContent {
  @override
  Future<List<LearningResource>> mentorPreviews(
    String id, {
    required int offset,
  }) async => [
    for (final key in ['one', 'two'])
      LearningResource(
        id: key,
        authorId: 'mentor',
        authorName: 'Mentor',
        title: 'Video $key',
        summary: 'Preview',
        category: 'Coding',
        level: 'Beginner',
        kind: 'Video',
        body: '',
        link: '',
        tags: [],
        status: 'published',
      ),
  ];
}

class PreviewCheckoutTutors extends AccountTutors {
  int checkouts = 0;
  @override
  Future<MentorPaymentOrder> prepareDemoPayment(String id) async {
    checkouts++;
    return super.prepareDemoPayment(id);
  }
}

void main() {
  testWidgets(
    'locked video preview loads no media and opens one existing checkout',
    (tester) async {
      tester.view.physicalSize = const Size(600, 2200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final tutors = PreviewCheckoutTutors()
        ..userId = 'student'
        ..accountRole = 'student';
      final content = TwoVideos();
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
      expect(find.text('Unlock to Watch'), findsNWidgets(2));
      expect(find.byType(UploadedVideoPlayer), findsNothing);
      expect(content.urls, 0);
      expect(find.byType(Image), findsNothing);
      final tap = tester
          .widget<InkWell>(find.byKey(const ValueKey('video-preview-one')))
          .onTap!;
      tap();
      tap();
      await tester.pumpAndSettle();
      expect(tutors.checkouts, 1);
      expect(find.byType(DemoCheckoutScreen), findsOneWidget);
      expect(content.urls, 0);
      await tester.pumpWidget(const SizedBox());
      await tutors.changes.close();
    },
  );
  for (final unlocked in [false, true]) {
    testWidgets(
      'preview fits narrow screen with large text unlocked=$unlocked',
      (tester) async {
        tester.view.physicalSize = const Size(320, 740);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final tutors = AccountTutors()
          ..userId = 'student'
          ..accountRole = 'student'
          ..materials = unlocked;
        final content = TwoVideos();
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: MentorDetailScreen(
              repository: tutors,
              mentor: mentor(),
              content: content,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('video-preview-one')),
          200,
          scrollable: find.byWidgetPredicate(
            (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
          ),
        );
        expect(content.urls, 0);
        expect(find.byType(UploadedVideoPlayer), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tutors.changes.close();
      },
    );
  }

  testWidgets(
    'Watch is lazy, repeated taps stay single, video/tab changes remove old player',
    (tester) async {
      tester.view.physicalSize = const Size(600, 2200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final tutors = AccountTutors()
        ..userId = 'student'
        ..accountRole = 'student'
        ..materials = true;
      final content = TwoVideos()..pendingUrl = Completer();
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
      final box = tester.getSize(
        find.byKey(const ValueKey('video-preview-one')),
      );
      expect(box.width / box.height, closeTo(16 / 9, 0.01));
      expect(content.urls, 0);
      expect(find.byType(UploadedVideoPlayer), findsNothing);
      final watch = tester
          .widget<InkWell>(find.byKey(const ValueKey('video-preview-one')))
          .onTap!;
      watch();
      watch();
      await tester.pump();
      expect(content.urls, 1);
      expect(find.byType(UploadedVideoPlayer), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('video-preview-two')));
      await tester.pump();
      expect(content.urls, 2);
      expect(find.byType(UploadedVideoPlayer), findsOneWidget);
      await tester.tap(find.text('Sessions'));
      await tester.pump();
      expect(find.byType(UploadedVideoPlayer), findsNothing);
      content.pendingUrl!.complete('https://fixture.invalid/late.mp4');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tutors.changes.close();
    },
  );

  test(
    'locked users never request URLs; authorized retry signs a fresh URL; revocation rejects',
    () async {
      final tutors = AccountTutors()
        ..userId = 'student'
        ..accountRole = 'student';
      final content = VideoContent();
      final vm = MentorDetailViewModel(tutors, 'mentor', content);
      await vm.load();
      await expectLater(vm.videoPlaybackUrl('one'), throwsStateError);
      expect(content.urls, 0);
      tutors.materials = true;
      expect(await vm.videoPlaybackUrl('one'), endsWith('/1.mp4'));
      expect(await vm.videoPlaybackUrl('one'), endsWith('/2.mp4'));
      tutors.materials = false;
      await expectLater(vm.videoPlaybackUrl('one'), throwsStateError);
      expect(content.urls, 2);
      tutors.materials = true;
      content.hidden = true;
      await expectLater(vm.videoPlaybackUrl('one'), throwsStateError);
      expect(content.urls, 2);
      content.hidden = false;
      content.deleted = true;
      await expectLater(vm.videoPlaybackUrl('one'), throwsStateError);
      expect(content.urls, 2);
      vm.dispose();
      await tutors.changes.close();
    },
  );
  test(
    'deduplicates initialization and rejects late signing after selection or account changes',
    () async {
      final tutors = AccountTutors()
        ..userId = 'student'
        ..accountRole = 'student'
        ..materials = true;
      final content = VideoContent()..pendingUrl = Completer();
      final vm = MentorDetailViewModel(tutors, 'mentor', content);
      await vm.load();
      final a = vm.videoPlaybackUrl('one');
      final b = vm.videoPlaybackUrl('one');
      final rejected = expectLater(Future.wait([a, b]), throwsStateError);
      await Future<void>.delayed(Duration.zero);
      expect(content.urls, 1);
      vm.invalidatePlayback();
      content.pendingUrl!.complete('https://fixture.invalid/old.mp4');
      await rejected;
      content.pendingUrl = Completer();
      final c = vm.videoPlaybackUrl('one');
      final stale = expectLater(c, throwsStateError);
      await Future<void>.delayed(Duration.zero);
      tutors.userId = 'other';
      tutors.changes.add('other');
      content.pendingUrl!.complete('https://fixture.invalid/old.mp4');
      await stale;
      vm.dispose();
      await tutors.changes.close();
    },
  );
  test('mentor owner keeps access and disposal rejects late URL', () async {
    final tutors = AccountTutors()
      ..userId = 'mentor'
      ..accountRole = 'mentor';
    final content = VideoContent()..pendingUrl = Completer();
    final vm = MentorDetailViewModel(tutors, 'mentor', content);
    await vm.load();
    final result = vm.videoPlaybackUrl('one');
    final rejected = expectLater(result, throwsStateError);
    await Future<void>.delayed(Duration.zero);
    expect(content.urls, 1);
    vm.dispose();
    content.pendingUrl!.complete('https://fixture.invalid/a');
    await rejected;
    await tutors.changes.close();
  });
}
