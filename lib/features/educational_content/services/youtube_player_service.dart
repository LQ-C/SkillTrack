import 'package:youtube_player_iframe/youtube_player_iframe.dart';

class YoutubePlayerService {
  static YoutubePlayerController create(String id) =>
      YoutubePlayerController.fromVideoId(
        videoId: id,
        autoPlay: true,
        params: const YoutubePlayerParams(
          showControls: true,
          showFullscreenButton: true,
          origin: 'https://com.skilltrack.skilltrack',
        ),
      );
}
