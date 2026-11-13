import 'dart:async';
import 'package:flutter/material.dart';
import 'package:youtube_player_iframe/youtube_player_iframe.dart';
import '../services/youtube_player_service.dart';
import 'package:skilltrack/app/router/navigation_observers.dart';
import 'package:skilltrack/features/educational_content/utils/youtube_url.dart';

class InlineYoutubeVideo extends StatefulWidget {
  const InlineYoutubeVideo({super.key, required this.url});
  final String url;
  @override
  State<InlineYoutubeVideo> createState() => _InlineYoutubeVideoState();
}

class _InlineYoutubeVideoState extends State<InlineYoutubeVideo>
    with WidgetsBindingObserver, RouteAware {
  YoutubePlayerController? controller;
  ModalRoute<dynamic>? route;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final currentRoute = ModalRoute.of(context);
    if (currentRoute != route) {
      videoRouteObserver.unsubscribe(this);
      route = currentRoute;
      if (currentRoute != null) {
        videoRouteObserver.subscribe(this, currentRoute);
      }
    }
  }

  @override
  void didUpdateWidget(covariant InlineYoutubeVideo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      controller?.close();
      controller = null;
    }
  }

  @override
  void didPushNext() {
    unawaited(controller?.pauseVideo());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) unawaited(controller?.pauseVideo());
  }

  @override
  void dispose() {
    videoRouteObserver.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    controller?.close();
    super.dispose();
  }

  void start(String id) {
    controller?.close();
    setState(() {
      controller = YoutubePlayerService.create(id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final id = youtubeVideoId(widget.url);
    if (id == null) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(20),
          child: Text(
            'This video cannot be played here. Ask the mentor to use a valid YouTube video link.',
          ),
        ),
      );
    }
    final player = controller;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (player == null)
          Container(
            constraints: const BoxConstraints(minHeight: 200),
            decoration: BoxDecoration(
              color: const Color(0xFF163F34),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: FilledButton.icon(
                  onPressed: () => start(id),
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Play video in SkillTrack'),
                ),
              ),
            ),
          )
        else ...[
          // Fullscreen is handled by the player's own Flutter overlay.
          LayoutBuilder(
            builder: (context, constraints) => YoutubePlayer(
              controller: player,
              aspectRatio:
                  constraints.maxWidth /
                  (constraints.maxWidth * 9 / 16).clamp(200, double.infinity),
            ),
          ),
          YoutubeValueBuilder(
            controller: player,
            builder: (context, value) {
              if (!value.hasError) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  'YouTube could not play this video (${value.error.code}). It may be private, unavailable, or restricted from embedded playback. Ask the mentor to check the video.',
                ),
              );
            },
          ),
          TextButton.icon(
            onPressed: () => start(id),
            icon: const Icon(Icons.refresh),
            label: const Text('Reload video'),
          ),
        ],
        const SizedBox(height: 10),
        const Text(
          'YouTube player · Internet connection required',
          style: TextStyle(fontSize: 12),
        ),
      ],
    );
  }
}
