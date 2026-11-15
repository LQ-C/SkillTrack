import 'package:flutter/services.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player/video_player.dart';
import 'package:skilltrack/features/educational_content/widgets/uploaded_video_player.dart';
import 'package:skilltrack/app/router/navigation_observers.dart';

class TestVideoController extends VideoPlayerController {
  TestVideoController()
    : super.networkUrl(Uri.parse('https://fixture.invalid/video.mp4'));
  bool disposed = false;
  int pauses = 0;
  @override
  Future<void> initialize() async {
    value = VideoPlayerValue(
      duration: const Duration(seconds: 20),
      isInitialized: true,
      size: const Size(320, 180),
    );
  }

  @override
  Future<void> play() async {
    value = value.copyWith(isPlaying: true);
  }

  @override
  Future<void> pause() async {
    pauses++;
    if (!disposed) value = value.copyWith(isPlaying: false);
  }

  @override
  Future<void> setVolume(double v) async {
    value = value.copyWith(volume: v);
  }

  @override
  Future<void> setPlaybackSpeed(double v) async {
    value = value.copyWith(playbackSpeed: v);
  }

  @override
  Future<void> seekTo(Duration p) async {
    value = value.copyWith(position: p);
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    super.dispose();
  }
}

void main() {
  testWidgets(
    'fullscreen shares playback position and supports standard controls',
    (tester) async {
      var loads = 0;
      final controller = TestVideoController();
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [videoRouteObserver],
          home: Scaffold(
            body: UploadedVideoPlayer(
              loadUrl: () async {
                loads++;
                return 'https://fixture.invalid/a';
              },
              controllerFactory: (_) => controller,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await controller.seekTo(const Duration(seconds: 5));
      await tester.pump();
      await tester.tap(find.byTooltip('Play video'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Fullscreen'));
      await tester.pumpAndSettle();
      tester.view.physicalSize = const Size(960, 440);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(VideoPlayer)).height, closeTo(440, 1));
      expect(tester.getSize(find.byType(VideoPlayer)).width, greaterThan(700));
      expect(find.byTooltip('Exit fullscreen'), findsOneWidget);
      expect(loads, 1);
      expect(controller.value.position.inSeconds, 5);
      expect(controller.value.isPlaying, true);
      await tester.tap(find.byTooltip('Forward 10 seconds').hitTestable());
      await tester.pump();
      expect(controller.value.position.inSeconds, 15);
      await tester.tap(find.byTooltip('Mute video').hitTestable());
      await tester.pump();
      expect(controller.value.volume, 0);
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Exit fullscreen'));
      await tester.pumpAndSettle();
      expect(controller.value.position.inSeconds, 15);
      expect(controller.disposed, false);
      expect(loads, 1);
      await tester.pumpWidget(const SizedBox());
      expect(controller.disposed, true);
    },
  );

  testWidgets('missing native plugin gives a rebuild instruction', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: UploadedVideoPlayer(
          loadUrl: () async => throw MissingPluginException('fixture'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.textContaining('missing the native video player'),
      findsOneWidget,
    );
    expect(find.text('Retry video'), findsOneWidget);
  });

  testWidgets(
    'controls, seeking, buffering, retry fresh URL and lifecycle pause',
    (tester) async {
      final controllers = <TestVideoController>[];
      var calls = 0;
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: nav,
          navigatorObservers: [videoRouteObserver],
          home: Scaffold(
            body: UploadedVideoPlayer(
              loadUrl: () async => 'https://fixture.invalid/${++calls}.mp4',
              controllerFactory: (url) {
                final c = TestVideoController();
                controllers.add(c);
                return c;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(calls, 1);
      await tester.tap(find.byTooltip('Play video'));
      await tester.pumpAndSettle();
      expect(controllers.last.value.isPlaying, true);
      await tester.tap(find.byType(VideoProgressIndicator));
      await tester.pumpAndSettle();
      expect(controllers.last.value.position.inSeconds, greaterThan(0));
      controllers.last.value = controllers.last.value.copyWith(
        isBuffering: true,
      );
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsWidgets);
      controllers.last.value = controllers.last.value.copyWith(
        isBuffering: false,
      );
      nav.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Other')),
        ),
      );
      await tester.pumpAndSettle();
      expect(controllers.last.value.isPlaying, false);
      nav.currentState!.pop();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Play video'));
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(controllers.last.value.isPlaying, false);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      controllers.last.value = controllers.last.value.copyWith(
        errorDescription: 'expired',
      );
      await tester.pump();
      await tester.tap(find.text('Retry video'));
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(controllers.first.disposed, true);
      await tester.pumpWidget(const SizedBox());
      expect(controllers.last.disposed, true);
    },
  );
  testWidgets(
    'late URL after removal never initializes controller; retries do not overlap',
    (tester) async {
      final pending = Completer<String>();
      var creates = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: UploadedVideoPlayer(
            loadUrl: () => pending.future,
            controllerFactory: (_) {
              creates++;
              return TestVideoController();
            },
          ),
        ),
      );
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      pending.complete('https://fixture.invalid/a.mp4');
      await tester.pumpAndSettle();
      expect(creates, 0);
    },
  );
  testWidgets('time and retry controls wrap at large text on a narrow screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(280, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            child: UploadedVideoPlayer(
              loadUrl: () async => 'https://fixture.invalid/a.mp4',
              controllerFactory: (_) => TestVideoController(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
