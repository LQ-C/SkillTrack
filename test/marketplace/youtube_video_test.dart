import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skilltrack/features/educational_content/widgets/inline_youtube_video.dart';
import 'package:skilltrack/features/educational_content/utils/youtube_url.dart';

void main() {
  test('recognizes YouTube watch, share, Shorts, live and embed links', () {
    for (final url in [
      'https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=test',
      'https://youtu.be/dQw4w9WgXcQ?si=abc',
      'https://m.youtube.com/watch?v=dQw4w9WgXcQ',
      'https://www.youtube.com/shorts/dQw4w9WgXcQ',
      'https://www.youtube.com/live/dQw4w9WgXcQ',
      'https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ',
    ]) {
      expect(youtubeVideoId(url), 'dQw4w9WgXcQ');
    }
  });
  test('rejects fake domains, playlists, malformed IDs and unsafe URLs', () {
    for (final url in [
      'https://youtube.com.evil.test/watch?v=dQw4w9WgXcQ',
      'https://evil.test/youtube.com/watch?v=dQw4w9WgXcQ',
      'https://youtube.com/playlist?list=test',
      'https://youtube.com/watch?v=short',
      'https://youtube.com/watch?v=dQw4w9WgXcQEXTRA',
      'https://user@youtube.com/watch?v=dQw4w9WgXcQ',
      'javascript:alert(1)',
      'http://youtu.be/dQw4w9WgXcQ',
    ]) {
      expect(youtubeVideoId(url), isNull);
    }
  });
  testWidgets(
    'video offers inline playback without an external navigation button',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: InlineYoutubeVideo(url: 'https://youtu.be/dQw4w9WgXcQ'),
          ),
        ),
      );
      expect(find.text('Play video in SkillTrack'), findsOneWidget);
      expect(
        find.textContaining('Internet connection required'),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.open_in_new), findsNothing);
    },
  );
  testWidgets('unsupported videos show guidance instead of a blank player', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: InlineYoutubeVideo(url: 'https://example.com/video'),
        ),
      ),
    );
    expect(find.textContaining('valid YouTube video link'), findsOneWidget);
    expect(find.text('Play video in SkillTrack'), findsNothing);
  });
}
