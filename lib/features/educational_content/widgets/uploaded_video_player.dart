import 'package:flutter/services.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import '../../../app/router/navigation_observers.dart';

class UploadedVideoPlayer extends StatefulWidget {
  const UploadedVideoPlayer({
    super.key,
    required this.loadUrl,
    this.controllerFactory,
  });
  final Future<String> Function() loadUrl;
  @visibleForTesting
  final VideoPlayerController Function(Uri)? controllerFactory;
  @override
  State<UploadedVideoPlayer> createState() => _UploadedVideoPlayerState();
}

class _UploadedVideoPlayerState extends State<UploadedVideoPlayer>
    with WidgetsBindingObserver, RouteAware {
  VideoPlayerController? _controller;
  VideoPlayerController? _initializing;
  ModalRoute<dynamic>? _route;
  String? _error;
  int _version = 0;
  bool _loading = false;
  bool _covered = false;
  bool _foreground = true;
  Route<bool>? _fullscreenRoute;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_load());
  }

  Future<void> _load() async {
    if (_loading) return;
    _loading = true;
    final version = ++_version;
    final old = _controller;
    setState(() {
      _controller = null;
      _error = null;
    });
    VideoPlayerController? next;
    var stage = 'access';
    try {
      if (old != null) await old.dispose();
      final url = await widget.loadUrl().timeout(const Duration(seconds: 30));
      if (!mounted || version != _version) return;
      stage = 'player';
      next =
          widget.controllerFactory?.call(Uri.parse(url)) ??
          VideoPlayerController.networkUrl(Uri.parse(url));
      _initializing = next;
      await next.initialize().timeout(const Duration(seconds: 30));
      if (!mounted || version != _version) {
        await next.dispose();
        return;
      }
      _initializing = null;
      setState(() => _controller = next);
    } catch (failure) {
      await next?.dispose();
      _initializing = null;
      if (mounted && version == _version) {
        setState(
          () => _error = failure is MissingPluginException
              ? 'This app build is missing the native video player. Stop the app and install a freshly rebuilt Android app.'
              : failure is TimeoutException
              ? 'Video ${stage == 'access' ? 'access check' : 'loading'} timed out. Check your connection and retry.'
              : stage == 'access'
              ? 'Could not authorize this video. Refresh your materials access and retry.'
              : 'The video player could not open this MP4. Retry, or check that the video uses an Android-supported encoding.',
        );
      }
    } finally {
      if (mounted && version == _version) setState(() => _loading = false);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (_route != route) {
      videoRouteObserver.unsubscribe(this);
      _route = route;
      if (route != null) videoRouteObserver.subscribe(this, route);
    }
  }

  @override
  void didPushNext() {
    if (_fullscreenRoute?.isCurrent == true) return;
    _covered = true;
    unawaited(_controller?.pause());
  }

  @override
  void didPopNext() {
    _covered = false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (state != AppLifecycleState.resumed) unawaited(_controller?.pause());
  }

  @override
  void dispose() {
    ++_version;
    videoRouteObserver.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    final fullscreen = _fullscreenRoute;
    if (fullscreen != null && fullscreen.isActive) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (fullscreen.isActive) fullscreen.navigator?.removeRoute(fullscreen);
      });
    }
    unawaited(_controller?.dispose());
    unawaited(_initializing?.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (_error != null) {
      return Column(
        children: [
          Text(_error!),
          TextButton(onPressed: _load, child: const Text('Retry video')),
        ],
      );
    }
    if (controller == null) {
      return const AspectRatio(
        aspectRatio: 16 / 9,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_fullscreenRoute != null) {
      return const AspectRatio(
        aspectRatio: 16 / 9,
        child: Center(child: Text('Playing fullscreen')),
      );
    }
    return _player(controller, fullscreen: false);
  }

  Future<void> _fullscreen(VideoPlayerController controller) async {
    if (_fullscreenRoute != null) return;
    final route = MaterialPageRoute<bool>(
      builder: (context) => Theme(
        data: ThemeData.dark().copyWith(
          colorScheme: ColorScheme.fromSeed(
            seedColor: Theme.of(context).colorScheme.primary,
            brightness: Brightness.dark,
          ),
        ),
        child: Scaffold(
          backgroundColor: Colors.black,
          body: _player(controller, fullscreen: true),
        ),
      ),
    );
    setState(() => _fullscreenRoute = route);
    final retry = await Navigator.of(context).push<bool>(route);
    if (!mounted) return;
    setState(() => _fullscreenRoute = null);
    if (retry == true) await _load();
  }

  Future<void> _seek(VideoPlayerController c, int seconds) async {
    final target = c.value.position + Duration(seconds: seconds);
    await c.seekTo(
      Duration(
        milliseconds: target.inMilliseconds.clamp(
          0,
          c.value.duration.inMilliseconds,
        ),
      ),
    );
  }

  Widget _player(
    VideoPlayerController controller, {
    required bool fullscreen,
  }) => ValueListenableBuilder<VideoPlayerValue>(
    valueListenable: controller,
    builder: (context, value, _) {
      final enabled = !value.hasError && !_covered && _foreground;
      final video = AspectRatio(
        aspectRatio: fullscreen ? value.aspectRatio : 16 / 9,
        child: ColoredBox(
          color: Colors.black,
          child: Center(
            child: AspectRatio(
              aspectRatio: value.aspectRatio,
              child: VideoPlayer(controller),
            ),
          ),
        ),
      );
      final controls = Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (value.isBuffering) const LinearProgressIndicator(),
            if (value.hasError)
              const Text('Playback failed. Try loading the video again.'),
            VideoProgressIndicator(controller, allowScrubbing: enabled),
            LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth >= 550;
                Widget button(
                  String label,
                  IconData icon,
                  VoidCallback? action,
                ) => IconButton(
                  tooltip: label,
                  visualDensity: VisualDensity.compact,
                  iconSize: 22,
                  onPressed: action,
                  icon: Icon(icon),
                );
                return Row(
                  children: [
                    button(
                      value.isPlaying ? 'Pause video' : 'Play video',
                      value.isPlaying ? Icons.pause : Icons.play_arrow,
                      !enabled
                          ? null
                          : () async {
                              try {
                                if (value.isPlaying) {
                                  await controller.pause();
                                } else {
                                  if (value.position >= value.duration) {
                                    await controller.seekTo(Duration.zero);
                                  }
                                  await controller.play();
                                }
                              } catch (_) {
                                if (mounted) {
                                  setState(
                                    () => _error =
                                        'Unable to play this video. Please retry.',
                                  );
                                }
                              }
                            },
                    ),
                    if (wide)
                      button(
                        'Back 10 seconds',
                        Icons.replay_10,
                        enabled ? () => _seek(controller, -10) : null,
                      ),
                    if (wide)
                      button(
                        'Forward 10 seconds',
                        Icons.forward_10,
                        enabled ? () => _seek(controller, 10) : null,
                      ),
                    Expanded(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          '${_time(value.position)} / ${_time(value.duration)}',
                        ),
                      ),
                    ),
                    if (wide)
                      button(
                        value.volume == 0 ? 'Unmute video' : 'Mute video',
                        value.volume == 0 ? Icons.volume_off : Icons.volume_up,
                        enabled
                            ? () => controller.setVolume(
                                value.volume == 0 ? 1 : 0,
                              )
                            : null,
                      ),
                    PopupMenuButton<String>(
                      tooltip: 'Video options',
                      enabled: enabled,
                      itemBuilder: (_) => [
                        if (!wide)
                          const PopupMenuItem(
                            value: 'back',
                            child: Text('Back 10 seconds'),
                          ),
                        if (!wide)
                          const PopupMenuItem(
                            value: 'forward',
                            child: Text('Forward 10 seconds'),
                          ),
                        if (!wide)
                          PopupMenuItem(
                            value: 'volume',
                            child: Text(
                              value.volume == 0 ? 'Unmute video' : 'Mute video',
                            ),
                          ),
                        for (final speed in [0.5, 1.0, 1.5, 2.0])
                          PopupMenuItem(
                            value: '$speed',
                            child: Text('Speed $speedÃ—'),
                          ),
                      ],
                      onSelected: (action) {
                        if (action == 'back') {
                          _seek(controller, -10);
                        } else if (action == 'forward') {
                          _seek(controller, 10);
                        } else if (action == 'volume') {
                          controller.setVolume(value.volume == 0 ? 1 : 0);
                        } else {
                          controller.setPlaybackSpeed(double.parse(action));
                        }
                      },
                    ),
                    button(
                      fullscreen ? 'Exit fullscreen' : 'Fullscreen',
                      fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                      fullscreen
                          ? () => Navigator.of(context).pop()
                          : enabled
                          ? () => _fullscreen(controller)
                          : null,
                    ),
                  ],
                );
              },
            ),
            if (value.hasError)
              TextButton(
                onPressed: () {
                  if (fullscreen) {
                    Navigator.of(context).pop(true);
                  } else {
                    _load();
                  }
                },
                child: const Text('Retry video'),
              ),
          ],
        ),
      );
      if (fullscreen) {
        return Stack(
          children: [
            Positioned.fill(child: Center(child: video)),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(
                top: false,
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: 0.7),
                  child: controls,
                ),
              ),
            ),
          ],
        );
      }
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [video, controls],
      );
    },
  );
  String _time(Duration d) =>
      '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
}
