import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player/video_player.dart';
import 'package:skilltrack/app/router/navigation_observers.dart';
import 'package:skilltrack/features/educational_content/widgets/uploaded_video_player.dart';
import 'uploaded_video_test.dart' show TestVideoController;

const chrome = ValueKey('fullscreen-video-controls');
bool visible(WidgetTester tester) =>
    tester.widget<AnimatedOpacity>(find.byKey(chrome)).opacity == 1;
Future<TestVideoController> showPlayer(
  WidgetTester tester, {
  bool accessible = false,
  bool reduced = false,
}) async {
  final controller = TestVideoController();
  await tester.pumpWidget(
    MaterialApp(
      navigatorObservers: [videoRouteObserver],
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          accessibleNavigation: accessible,
          disableAnimations: reduced,
        ),
        child: child!,
      ),
      home: Scaffold(
        body: UploadedVideoPlayer(
          loadUrl: () async => 'https://fixture.invalid/authorised.mp4',
          controllerFactory: (_) => controller,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await controller.seekTo(const Duration(seconds: 5));
  await tester.tap(find.byTooltip('Play video'));
  await tester.pump();
  await tester.tap(find.byTooltip('Fullscreen'));
  await tester.pumpAndSettle();
  return controller;
}

Future<void> tapVideo(WidgetTester tester) => tester.tapAt(
  tester.getTopLeft(find.byKey(const ValueKey('fullscreen-video-surface'))) +
      const Offset(100, 100),
);
Future<void> removePlayer(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
}

void main() {
  testWidgets(
    'playing hides after inactivity, taps toggle, interactions restart timer',
    (tester) async {
      final controller = await showPlayer(tester);
      expect(visible(tester), true);
      await tester.pump(const Duration(seconds: 2));
      // A control interaction starts a fresh interval, without restarting playback.
      await tester.tap(find.byTooltip('Video options'));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 2));
      expect(visible(tester), true);
      await tester.pump(const Duration(seconds: 2));
      expect(visible(tester), false);
      await tapVideo(tester);
      await tester.pump();
      expect(visible(tester), true);
      await tapVideo(tester);
      await tester.pump();
      expect(visible(tester), false);
      expect(controller.value.position, const Duration(seconds: 5));
      await removePlayer(tester);
    },
  );
  testWidgets('paused, ended and failed playback keep controls visible', (
    tester,
  ) async {
    final controller = await showPlayer(tester);
    await tester.pump(const Duration(seconds: 4));
    expect(visible(tester), false);
    await controller.pause();
    await tester.pump();
    expect(visible(tester), true);
    await tester.pump(const Duration(seconds: 5));
    expect(visible(tester), true);
    controller.value = controller.value.copyWith(
      isPlaying: true,
      position: controller.value.duration,
      isCompleted: true,
    );
    await tester.pump(const Duration(seconds: 5));
    expect(visible(tester), true);
    controller.value = controller.value.copyWith(
      position: Duration.zero,
      isCompleted: false,
      errorDescription: 'fixture',
    );
    await tester.pump(const Duration(seconds: 5));
    expect(visible(tester), true);
    expect(find.text('Retry video'), findsOneWidget);
    await removePlayer(tester);
  });
  testWidgets(
    'menu stays open without hiding or pausing; closing restarts timer',
    (tester) async {
      final controller = await showPlayer(tester);
      await tester.tap(find.byTooltip('Video options'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 5));
      expect(visible(tester), true);
      expect(controller.value.isPlaying, true);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 4));
      expect(visible(tester), false);
      await removePlayer(tester);
    },
  );
  testWidgets('dragging the progress bar holds controls until seek completes', (
    tester,
  ) async {
    final controller = await showPlayer(tester);
    final bar = find.byType(VideoProgressIndicator);
    final gesture = await tester.startGesture(tester.getCenter(bar));
    await gesture.moveBy(const Offset(60, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(60, 0));
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    expect(visible(tester), true);
    await gesture.up();
    await tester.pump();
    expect(controller.value.position, isNot(const Duration(seconds: 5)));
    await tester.pump(const Duration(seconds: 4));
    expect(visible(tester), false);
    await removePlayer(tester);
  });
  testWidgets(
    'accessibility retains controls and reduced motion uses no fade',
    (tester) async {
      await showPlayer(tester, accessible: true, reduced: true);
      await tester.pump(const Duration(seconds: 5));
      expect(visible(tester), true);
      await tapVideo(tester);
      await tester.pump();
      expect(visible(tester), true);
      expect(
        tester.widget<AnimatedOpacity>(find.byKey(chrome)).duration,
        Duration.zero,
      );
      await removePlayer(tester);
    },
  );
  testWidgets(
    'fullscreen exit shares position; inline remains visible; listeners and timers clean up',
    (tester) async {
      final controller = await showPlayer(tester);
      await controller.seekTo(const Duration(seconds: 9));
      await tester.tap(find.byTooltip('Exit fullscreen'));
      await tester.pumpAndSettle();
      expect(controller.value.position, const Duration(seconds: 9));
      expect(controller.disposed, false);
      await tester.pump(const Duration(seconds: 5));
      expect(find.byTooltip('Pause video').hitTestable(), findsOneWidget);
      expect(find.byKey(chrome), findsNothing);
      await removePlayer(tester);
      expect(controller.disposed, true);
      await tester.pump(const Duration(seconds: 5));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'backgrounding and navigating above fullscreen pause the shared player',
    (tester) async {
      final controller = await showPlayer(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(controller.value.isPlaying, false);
      expect(visible(tester), true);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.tap(find.byTooltip('Play video'));
      await tester.pump();
      final context = tester.element(find.byKey(chrome));
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Other page')),
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.value.isPlaying, false);
      await removePlayer(tester);
    },
  );
}
