import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:skilltrack/features/educational_content/repositories/supabase_content_repository.dart';
import 'package:skilltrack/features/educational_content/models/learning_resource.dart';

const owner = '00000000-0000-4000-8000-000000000001';
const path = '$owner/0123456789abcdef0123456789abcdef';

class Repo extends SupabaseContentRepository {
  Repo(super.client);
  @override
  String get userId => owner;
}

LearningResource resource(String kind, String link, {String? attachment}) =>
    LearningResource(
      id: owner,
      authorId: owner,
      authorName: 'Fixture',
      title: 'Fixture resource',
      summary: 'Fixture',
      category: 'Programming',
      level: 'Beginner',
      kind: kind,
      body: '',
      link: link,
      tags: [],
      status: 'published',
      attachmentPath: attachment,
    );
void main() {
  late SupabaseClient client;
  late Repo repo;
  late List<http.Request> requests;
  late Map<String, dynamic> saved;
  setUp(() {
    requests = [];
    saved = {};
    client = SupabaseClient(
      'https://fixture.supabase.co',
      'fixture-public-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        requests.add(request);
        if (request.url.path.contains('/object/sign/')) {
          return http.Response(
            jsonEncode({'signedURL': '/object/sign/fixture?token=fixture'}),
            200,
          );
        }
        if (request.url.path.startsWith('/storage/v1/object/')) {
          return http.Response(
            jsonEncode({
              'Key': request.url.path.split('/object/').last,
              'Id': owner,
            }),
            200,
          );
        }
        if (request.url.path == '/rest/v1/learning_resources') {
          saved = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({'id': owner}),
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }
        throw StateError('Unexpected fixture request');
      }),
    );
    repo = Repo(client);
  });
  tearDown(() => client.dispose());
  for (final ext in ['pdf', 'png', 'jpg', 'jpeg', 'mp4']) {
    test(
      'new $ext upload uses typed private bucket and stable reference',
      () async {
        final video = ext == 'mp4',
            bucket = ext == 'mp4'
                ? 'mentor-video-files'
                : 'mentor-reading-files';
        await repo.saveResourceFile(
          {'kind': video ? 'Video' : 'Reading'},
          'fixture.$ext',
          Uint8List.fromList([1, 2, 3]),
        );
        expect(
          requests.first.url.path,
          startsWith('/storage/v1/object/$bucket/$owner/'),
        );
        expect(saved['author_id'], owner);
        expect(saved['attachment_path'], endsWith('.$ext'));
        expect(
          saved['external_url'],
          'https://fixture.supabase.co/storage/v1/object/authenticated/$bucket/${saved['attachment_path']}',
        );
      },
    );
  }
  for (final bucket in [
    'mentor-video-files',
    'mentor-reading-files',
    'marketplace-videos',
  ]) {
    test('signed MP4 reads retain actual $bucket reference', () async {
      final link =
          'https://fixture.supabase.co/storage/v1/object/authenticated/$bucket/$path.mp4';
      await repo.primaryFileUrl(
        resource(
          'Video',
          link,
          attachment: bucket.startsWith('mentor-') ? '$path.mp4' : null,
        ),
      );
      expect(
        requests.single.url.path,
        '/storage/v1/object/sign/$bucket/$path.mp4',
      );
    });
  }
  test('path-only old MP4 keeps reading bucket', () async {
    await repo.primaryFileUrl(resource('Video', '', attachment: '$path.mp4'));
    expect(requests.single.url.path, contains('/sign/mentor-reading-files/'));
  });
  test(
    'invalid type, mismatched kind, empty and oversized files never upload',
    () async {
      for (final args in [
        ('bad.exe', 'Reading', Uint8List(1)),
        ('bad.mp4', 'Reading', Uint8List(1)),
        ('empty.pdf', 'Reading', Uint8List(0)),
        ('large.pdf', 'Reading', Uint8List(10 * 1024 * 1024 + 1)),
        ('large.mp4', 'Video', Uint8List(50 * 1024 * 1024 + 1)),
      ]) {
        await expectLater(
          repo.saveResourceFile({'kind': args.$2}, args.$1, args.$3),
          throwsFormatException,
        );
      }
      expect(requests, isEmpty);
    },
  );
  test(
    'foreign, signed, traversal, wrong bucket/kind and mismatched attachments fail before signing',
    () async {
      final root =
          'https://fixture.supabase.co/storage/v1/object/authenticated';
      for (final item in [
        resource(
          'Video',
          'https://foreign.invalid/storage/v1/object/authenticated/mentor-video-files/$path.mp4',
        ),
        resource('Video', '$root/mentor-video-files/$path.mp4?token=bad'),
        resource('Video', '$root/mentor-video-files/$owner/%2e%2e/video.mp4'),
        resource('Video', '$root/mentor-video-files/$owner/a%5Cb.mp4'),
        resource('Reading', '$root/mentor-video-files/$path.mp4'),
        resource('Video', '$root/task-attachments/$path.mp4'),
        resource(
          'Video',
          '$root/mentor-video-files/$path.mp4',
          attachment: '$path-other.mp4',
        ),
      ]) {
        await expectLater(repo.primaryFileUrl(item), throwsFormatException);
      }
      expect(requests, isEmpty);
    },
  );
  for (final ext in ['pdf', 'png', 'jpg', 'jpeg']) {
    test('signed $ext opening stays in the reading bucket', () async {
      await repo.primaryFileUrl(
        resource(
          'Reading',
          'https://fixture.supabase.co/storage/v1/object/authenticated/mentor-reading-files/$path.$ext',
          attachment: '$path.$ext',
        ),
      );
      expect(
        requests.single.url.path,
        '/storage/v1/object/sign/mentor-reading-files/$path.$ext',
      );
    });
  }
  test('denied signing fails without probing another bucket', () async {
    final calls = <String>[];
    final denied = SupabaseClient(
      'https://fixture.supabase.co',
      'fixture-public-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((r) async {
        calls.add(r.url.path);
        return http.Response(
          jsonEncode({
            'statusCode': '403',
            'error': 'Access denied',
            'message': 'Access denied',
          }),
          403,
          request: r,
        );
      }),
    );
    addTearDown(denied.dispose);
    await expectLater(
      Repo(denied).primaryFileUrl(
        resource(
          'Video',
          'https://fixture.supabase.co/storage/v1/object/authenticated/mentor-video-files/$path.mp4',
          attachment: '$path.mp4',
        ),
      ),
      throwsA(isA<StorageException>()),
    );
    expect(calls, ['/storage/v1/object/sign/mentor-video-files/$path.mp4']);
  });
}
