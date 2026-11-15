import 'dart:math';
import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:skilltrack/features/educational_content/models/learning_resource.dart';
import 'package:skilltrack/features/educational_content/repositories/content_repository.dart';

class SupabaseContentRepository
    implements
        ContentRepository,
        ContentSessionSource,
        MentorResourcePreviewRepository,
        ResourceFileRepository,
        ResourceOpeningRepository {
  SupabaseContentRepository(this.client);
  final SupabaseClient client;
  @override
  Stream<String?> get userChanges =>
      client.auth.onAuthStateChange.map((e) => e.session?.user.id).distinct();
  static const resourceFilesBucket = 'mentor-reading-files';
  static const videoFilesBucket = 'mentor-video-files';

  void _validatePath(String path) {
    if (path.isEmpty ||
        path.length > 1024 ||
        path
            .split('/')
            .any((part) => part.isEmpty || part == '.' || part == '..') ||
        RegExp(r'[\\\x00-\x1f\x7f]').hasMatch(path)) {
      throw const FormatException('Invalid private file path.');
    }
  }

  void _validateKind(String bucket, String path, String kind) {
    final extension = path.split('.').last.toLowerCase();
    final valid = switch (bucket) {
      videoFilesBucket => kind == 'Video' && extension == 'mp4',
      resourceFilesBucket =>
        kind == 'Video'
            ? extension == 'mp4'
            : kind == 'Reading' &&
                  {'pdf', 'png', 'jpg', 'jpeg'}.contains(extension),
      'marketplace-videos' => kind == 'Video',
      'marketplace-documents' => kind == 'Reading',
      _ => false,
    };
    if (!valid) {
      throw const FormatException(
        'File type does not match its resource bucket.',
      );
    }
  }

  @override
  Future<String> resourceFileUrl(String path) {
    // Path-only records predate the split and always belong to the old bucket.
    _validatePath(path);
    return client.storage
        .from(resourceFilesBucket)
        .createSignedUrl(path, path.toLowerCase().endsWith('.mp4') ? 900 : 120);
  }

  @override
  Future<String> primaryFileUrl(LearningResource resource) async {
    if (resource.link.isEmpty && resource.attachmentPath != null) {
      _validateKind(
        resourceFilesBucket,
        resource.attachmentPath!,
        resource.kind,
      );
      return resourceFileUrl(resource.attachmentPath!);
    }
    if (resource.link
        .split('/')
        .any((part) => {'.', '..'}.contains(Uri.decodeComponent(part)))) {
      throw const FormatException('Invalid private file path.');
    }
    final uri = Uri.tryParse(resource.link);
    final project = Uri.parse(client.rest.url);
    final parts = uri?.pathSegments ?? const <String>[];
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.origin != project.origin ||
        uri.hasQuery ||
        uri.hasFragment ||
        parts.length < 6 ||
        parts.take(3).join('/') != 'storage/v1/object' ||
        !{'public', 'authenticated'}.contains(parts[3]) ||
        !{
          resourceFilesBucket,
          videoFilesBucket,
          'marketplace-documents',
          'marketplace-videos',
        }.contains(parts[4])) {
      throw const FormatException('Unsupported private file reference.');
    }
    final path = parts.skip(5).join('/');
    _validatePath(path);
    if (resource.attachmentPath != null && resource.attachmentPath != path) {
      throw const FormatException(
        'Private file reference does not match its attachment.',
      );
    }
    _validateKind(parts[4], path, resource.kind);
    return client.storage
        .from(parts[4])
        .createSignedUrl(path, resource.kind == 'Video' ? 900 : 120);
  }

  @override
  Future<void> saveResourceFile(
    Map<String, dynamic> values,
    String name,
    Uint8List bytes, {
    String? id,
  }) async {
    final extension = name.split('.').last.toLowerCase();
    final mime = switch (extension) {
      'pdf' => 'application/pdf',
      'png' => 'image/png',
      'jpg' || 'jpeg' => 'image/jpeg',
      'mp4' => 'video/mp4',
      _ => throw const FormatException('Choose an MP4, PDF, PNG or JPEG file.'),
    };
    final video = extension == 'mp4';
    if (values['kind'] != (video ? 'Video' : 'Reading')) {
      throw const FormatException('Choose a file matching the resource type.');
    }
    final limit = (video ? 50 : 10) * 1024 * 1024;
    if (bytes.isEmpty || bytes.length > limit) {
      throw FormatException(
        'Choose a non-empty file up to ${video ? 50 : 10} MB.',
      );
    }
    final bucket = video ? videoFilesBucket : resourceFilesBucket;
    final owner = userId;
    final random = Random.secure();
    final key = List.generate(
      16,
      (_) => random.nextInt(256),
    ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    final path = '$owner/$key.$extension';
    await client.storage
        .from(bucket)
        .uploadBinary(path, bytes, fileOptions: FileOptions(contentType: mime));
    if (userId != owner) throw StateError('Session changed during upload.');
    await save({
      ...values,
      'external_url': client.storage
          .from(bucket)
          .getPublicUrl(path)
          .replaceFirst('/object/public/', '/object/authenticated/'),
      'attachment_path': path,
    }, id: id);
  }

  @override
  String get userId => client.auth.currentUser!.id;
  @override
  Future<({bool mentor, bool publisher})> permissions() async {
    final owner = userId;
    final results = await Future.wait<dynamic>([
      client.from('profiles').select('role').eq('id', owner).single(),
      client
          .from('content_publishers')
          .select('user_id')
          .eq('user_id', owner)
          .maybeSingle(),
    ]);
    if (userId != owner) throw StateError('Session changed');
    return (
      mentor: results[0]['role'] == 'mentor',
      publisher: results[1] != null,
    );
  }

  @override
  Future<List<LearningResource>> mentorPreviews(
    String mentorId, {
    required int offset,
  }) async {
    final rows = await client.rpc(
      'mentor_resource_previews',
      params: {'p_mentor': mentorId, 'p_offset': offset},
    );
    return (rows as List)
        .map((r) => LearningResource.fromJson(Map<String, dynamic>.from(r)))
        .toList();
  }

  @override
  Future<List<LearningResource>> list({
    required bool mine,
    required String search,
    String? category,
    String? level,
    String? kind,
    required int offset,
  }) async {
    var query = client.from('learning_resources').select();
    if (mine) {
      query = query.eq('author_id', userId);
    } else {
      query = query.eq('status', 'published').eq('moderation_hidden', false);
    }
    final term = search.trim().replaceAll(RegExp(r'[%_\\]'), '');
    if (term.isNotEmpty) query = query.ilike('title', '%$term%');
    if (category != null) query = query.eq('category', category);
    if (level != null) query = query.eq('difficulty', level);
    if (kind != null) query = query.eq('kind', kind);
    final rows = await query
        .order('created_at', ascending: false)
        .order('id')
        .range(offset, offset + 19);
    return rows.map(LearningResource.fromJson).toList();
  }

  @override
  Future<LearningResource> get(String id) async => LearningResource.fromJson(
    await client.from('learning_resources').select().eq('id', id).single(),
  );
  @override
  Future<Set<String>> bookmarks() async {
    final rows = await client
        .from('content_bookmarks')
        .select('resource_id')
        .eq('user_id', userId);
    return rows.map((r) => r['resource_id'] as String).toSet();
  }

  @override
  Future<void> bookmark(String id, bool save) async {
    if (save) {
      await client
          .from('content_bookmarks')
          .upsert(
            {'user_id': userId, 'resource_id': id},
            onConflict: 'user_id,resource_id',
            ignoreDuplicates: true,
          );
    } else {
      await client
          .from('content_bookmarks')
          .delete()
          .eq('user_id', userId)
          .eq('resource_id', id);
    }
  }

  @override
  Future<void> save(Map<String, dynamic> values, {String? id}) async {
    if (id == null) {
      await client
          .from('learning_resources')
          .insert({...values, 'author_id': userId})
          .select('id')
          .single();
    } else {
      await client
          .from('learning_resources')
          .update(values)
          .eq('id', id)
          .eq('author_id', userId)
          .select('id')
          .single();
    }
  }

  @override
  Future<void> delete(String id) async {
    await client
        .from('learning_resources')
        .delete()
        .eq('id', id)
        .eq('author_id', userId)
        .select('id')
        .single();
  }

  @override
  Future<void> report(String id, String reason, String details) async {
    await client.from('content_reports').insert({
      'resource_id': id,
      'reporter_id': userId,
      'reason': reason,
      'details': details.trim(),
    });
  }
}
