import 'dart:math';
import 'dart:convert';
import 'package:http/http.dart' as http;
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
        ResourceOpeningRepository,
        ResourcePdfRepository {
  SupabaseContentRepository(
    this.client, {
    http.Client Function()? pdfClientFactory,
  }) : _pdfClientFactory = pdfClientFactory ?? http.Client.new;
  final http.Client Function() _pdfClientFactory;
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

  /// Shared validation for classification and private URL signing.
  ({String bucket, String path}) _primaryFileReference(
    LearningResource resource,
  ) {
    if (resource.link.isEmpty && resource.attachmentPath != null) {
      _validateKind(
        resourceFilesBucket,
        resource.attachmentPath!,
        resource.kind,
      );
      _validatePath(resource.attachmentPath!);
      return (bucket: resourceFilesBucket, path: resource.attachmentPath!);
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
    return (bucket: parts[4], path: path);
  }

  @override
  bool isImageFile(LearningResource resource) {
    if (resource.kind != 'Reading') return false;
    try {
      final file = _primaryFileReference(resource);
      return {
        'png',
        'jpg',
        'jpeg',
      }.contains(file.path.split('.').last.toLowerCase());
    } on FormatException {
      return false;
    }
  }

  @override
  bool isPdfFile(LearningResource resource) {
    if (resource.kind != 'Reading') return false;
    try {
      return _primaryFileReference(
        resource,
      ).path.toLowerCase().endsWith('.pdf');
    } on FormatException {
      return false;
    }
  }

  @override
  Future<Uint8List> downloadPdf(String id) async {
    final owner = userId;
    var sameSession = true;
    final transport = _pdfClientFactory();
    final session = userChanges.listen((id) {
      if (id != owner) {
        sameSession = false;
        transport.close();
      }
    });
    bool current() => sameSession && client.auth.currentUser?.id == owner;
    Future<Uint8List> fetch() async {
      // The fresh full-row read uses resource RLS; signing also uses Storage RLS.
      final resource = await get(id);
      if (!current() ||
          resource.id != id ||
          !isPdfFile(resource) ||
          (resource.authorId != owner &&
              (resource.status != 'published' || resource.hidden))) {
        throw const FormatException('This PDF is no longer available.');
      }
      final url = await primaryFileUrl(resource);
      if (!current()) throw StateError('Session changed.');
      final uri = Uri.parse(url);
      if (uri.scheme != 'https' ||
          uri.origin != Uri.parse(client.rest.url).origin) {
        throw const FormatException('Invalid PDF download reference.');
      }
      final response = await transport.send(
        http.Request('GET', uri)..followRedirects = false,
      );
      if (response.statusCode != 200) {
        throw const FormatException(
          'Could not download this PDF. Retry to refresh access.',
        );
      }
      const limit = 25 * 1024 * 1024;
      if ((response.contentLength ?? 0) > limit) {
        throw const FormatException('This PDF exceeds the 25 MB reader limit.');
      }
      final data = BytesBuilder(copy: false);
      await for (final chunk in response.stream) {
        if (!current()) throw StateError('Session changed.');
        if (data.length + chunk.length > limit) {
          throw const FormatException(
            'This PDF exceeds the 25 MB reader limit.',
          );
        }
        data.add(chunk);
      }
      final bytes = data.takeBytes();
      if (!current()) throw StateError('Session changed.');
      if (!latin1.decode(bytes.take(1024).toList()).contains('%PDF-')) {
        throw const FormatException(
          'The uploaded file is not a supported PDF.',
        );
      }
      return bytes;
    }

    try {
      return await fetch().timeout(const Duration(seconds: 45));
    } finally {
      transport.close();
      await session.cancel();
    }
  }

  @override
  Future<String> primaryFileUrl(LearningResource resource) async {
    final file = _primaryFileReference(resource);
    return client.storage
        .from(file.bucket)
        .createSignedUrl(file.path, resource.kind == 'Video' ? 900 : 120);
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
