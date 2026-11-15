import 'dart:async';
import 'package:skilltrack/core/utils/view_model.dart';
import 'package:skilltrack/core/errors/content_errors.dart';
import '../models/learning_resource.dart';
import '../repositories/content_repository.dart';

class ResourceDetailViewModel extends ViewModel {
  ResourceDetailViewModel(
    this.repository,
    this.id, {
    required this.bookmarked,
  }) {
    _owner = _user;
    if (repository is ContentSessionSource) {
      _session = (repository as ContentSessionSource).userChanges.listen((
        user,
      ) {
        if (!isActive || user == _owner) return;
        _owner = user;
        _epoch++;
        _loadPending = null;
        _imagePending = null;
        update(() {
          resource = null;
          imageUrl = null;
          loading = imageLoading = busy = bookmarked = false;
          imageError = error = success = null;
        });
      });
    }
  }
  final ContentRepository repository;
  final String id;
  LearningResource? resource;
  bool loading = true, busy = false, bookmarked;
  String? error, success;
  String? imageUrl, imageError;
  bool imageLoading = false;
  String? _owner;
  int _epoch = 0, _resourceVersion = 0;
  Future<void>? _loadPending, _imagePending;
  StreamSubscription<String?>? _session;
  String? get _user {
    try {
      return repository.userId;
    } catch (_) {
      return null;
    }
  }

  bool _current(int epoch) =>
      isActive && epoch == _epoch && _owner != null && _user == _owner;
  bool get ownsResource => resource != null && resource!.authorId == _user;
  bool get isPdf =>
      resource != null &&
      repository is ResourcePdfRepository &&
      (repository as ResourcePdfRepository).isPdfFile(resource!);
  bool get isImage =>
      resource != null &&
      repository is ResourceOpeningRepository &&
      (repository as ResourceOpeningRepository).isImageFile(resource!);
  bool _available(LearningResource value) =>
      value.id == id &&
      (value.authorId == _owner ||
          (value.status == 'published' && !value.hidden));

  Future<void> load() {
    if (_loadPending != null) return _loadPending!;
    late final Future<void> pending;
    pending = _load().whenComplete(() {
      if (identical(_loadPending, pending)) _loadPending = null;
    });
    return _loadPending = pending;
  }

  Future<void> _load() async {
    final epoch = _epoch, version = ++_resourceVersion;
    bool valid() => _current(epoch) && version == _resourceVersion;
    if (!valid()) return;
    _imagePending = null;
    update(() {
      loading = true;
      error = imageError = imageUrl = null;
      imageLoading = false;
    });
    try {
      // Full-row RLS checks ownership, moderation and paid access.
      final value = await repository
          .get(id)
          .timeout(const Duration(seconds: 20));
      if (!valid()) return;
      if (!_available(value)) throw StateError('Resource unavailable.');
      update(() {
        resource = value;
        loading = false;
      });
      if (isImage) await _requestImage(value);
    } catch (e) {
      if (valid()) {
        update(() {
          resource = null;
          imageUrl = null;
          error = contentError(e);
        });
      }
    } finally {
      if (valid()) update(() => loading = false);
    }
  }

  /// Retry/enlarge always re-reads the resource before obtaining a fresh URL.
  Future<void> loadImage() => _requestImage();
  Future<void> _requestImage([LearningResource? justAuthorised]) {
    if (_imagePending != null) return _imagePending!;
    late final Future<void> pending;
    pending = _loadImage(justAuthorised).whenComplete(() {
      if (identical(_imagePending, pending)) _imagePending = null;
    });
    return _imagePending = pending;
  }

  Future<void> _loadImage(LearningResource? justAuthorised) async {
    final epoch = _epoch, version = _resourceVersion;
    bool valid() => _current(epoch) && version == _resourceVersion;
    if (!valid() || !isImage) return;
    update(() {
      imageLoading = true;
      imageUrl = imageError = null;
    });
    var authorised = justAuthorised != null;
    try {
      final value =
          justAuthorised ??
          await repository.get(id).timeout(const Duration(seconds: 20));
      if (!valid()) return;
      if (!_available(value)) throw StateError('Resource unavailable.');
      update(() => resource = value);
      authorised = true;
      if (!isImage) throw StateError('Image unavailable.');
      final url = await (repository as ResourceOpeningRepository)
          .primaryFileUrl(value)
          .timeout(const Duration(seconds: 20));
      if (valid()) update(() => imageUrl = url);
    } catch (_) {
      if (valid()) {
        update(() {
          imageUrl = null;
          imageError =
              'Could not load this image. Check your access and connection, then retry.';
          // Do not retain full resource content when a new authorised read failed.
          if (!authorised) resource = null;
        });
      }
    } finally {
      if (valid()) update(() => imageLoading = false);
    }
  }

  Future<String> videoPlaybackUrl() async {
    final epoch = _epoch, version = _resourceVersion;
    bool valid() => _current(epoch) && version == _resourceVersion;
    if (!valid()) throw StateError('Session changed.');
    final value = await repository.get(id);
    if (!valid() ||
        !_available(value) ||
        value.kind != 'Video' ||
        repository is! ResourceOpeningRepository) {
      throw StateError('Video unavailable.');
    }
    final url = await (repository as ResourceOpeningRepository).primaryFileUrl(
      value,
    );
    if (!valid()) throw StateError('Session changed.');
    return url;
  }

  Future<void> action(Future<void> Function() work) async {
    final epoch = _epoch;
    if (busy || !_current(epoch)) return;
    update(() {
      busy = true;
      error = success = null;
    });
    try {
      await work();
    } catch (e) {
      if (_current(epoch)) update(() => error = contentError(e));
    } finally {
      if (_current(epoch)) update(() => busy = false);
    }
  }

  Future<void> toggleBookmark() => action(() async {
    final epoch = _epoch;
    final save = !bookmarked;
    await repository.bookmark(id, save);
    if (_current(epoch)) update(() => bookmarked = save);
  });
  Future<void> report(String reason, String details) => action(() async {
    final epoch = _epoch;
    await repository.report(id, reason, details);
    if (_current(epoch)) {
      update(() => success = 'Report submitted for review. Thank you.');
    }
  });
  @override
  void dispose() {
    _epoch++;
    _session?.cancel();
    super.dispose();
  }
}
