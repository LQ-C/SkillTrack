import '../../profile/repositories/profile_repository.dart';
import 'dart:async';
import '../../../core/utils/debug_timing.dart';
import 'package:skilltrack/core/utils/view_model.dart';
import 'package:skilltrack/core/errors/content_errors.dart';
import '../models/learning_resource.dart';
import '../repositories/content_repository.dart';

class ContentLibraryViewModel extends ViewModel {
  ContentLibraryViewModel(this.repository, {ProfileChangeSource? profiles}) {
    _profileChanges = profiles?.profileChanges.listen((user) {
      if (!isActive || profiles.userId != user) return;
      try {
        if (repository.userId != user) return;
      } catch (_) {
        return;
      }
      _invalidate();
      unawaited(load());
    });
    if (repository is ContentSessionSource) {
      _sessionUser = repository.userId;
      _session = (repository as ContentSessionSource).userChanges.listen((
        user,
      ) {
        if (user == _sessionUser) return;
        _sessionUser = user;
        _invalidate();
      });
    }
  }
  void _invalidate() {
    request++;
    _pending.clear();
    _metadataUser = null;
    update(() {
      resources = [];
      bookmarks = {};
      accessLoaded = false;
      mentor = false;
      mine = false;
      publisher = false;
      more = false;
      loading = false;
      error = null;
    });
  }

  StreamSubscription<String>? _profileChanges;
  String? _sessionUser;
  StreamSubscription<String?>? _session;
  @override
  void dispose() {
    _session?.cancel();
    _profileChanges?.cancel();
    super.dispose();
  }

  final ContentRepository repository;
  String search = '';
  List<LearningResource> resources = [];
  Set<String> bookmarks = {};
  String? category, level, kind, error;
  bool mine = false,
      loading = true,
      more = false,
      mentor = false,
      publisher = false;
  bool accessLoaded = false;
  bool hasAccessibleMaterials = true;
  int request = 0;
  String? _metadataUser;
  final _pending = <Object, Future<void>>{};
  Future<void> load({bool append = false, bool refreshMetadata = true}) {
    final owner = repository.userId;
    final metadata = refreshMetadata && !append;
    final key = (owner, search, category, level, kind, append, metadata);
    final existing = _pending[key];
    if (existing != null) return existing;
    final future = _load(
      append: append,
      refreshMetadata: metadata,
      owner: owner,
    );
    late final Future<void> tracked;
    tracked = future.whenComplete(() {
      if (identical(_pending[key], tracked)) _pending.remove(key);
    });
    _pending[key] = tracked;
    return tracked;
  }

  Future<void> _load({
    required bool append,
    required bool refreshMetadata,
    required String owner,
  }) async {
    final current = ++request;
    final offset = append ? resources.length : 0;
    final query = search,
        queryCategory = category,
        queryLevel = level,
        queryKind = kind;
    bool valid() {
      if (!isActive || current != request) return false;
      try {
        return repository.userId == owner;
      } catch (_) {
        return false;
      }
    }

    if (_metadataUser != null && _metadataUser != owner) {
      resources = [];
      bookmarks = {};
      accessLoaded = false;
      _metadataUser = null;
    }
    update(() {
      loading = true;
      error = null;
    });
    try {
      final metadataNeeded =
          refreshMetadata || !accessLoaded || _metadataUser != owner;
      if (metadataNeeded) {
        final access = await debugTimed(
          'Library permissions',
          repository.permissions,
        );
        if (!valid()) return;
        update(() {
          mentor = access.mentor;
          mine = mentor;
          publisher = access.publisher;
          accessLoaded = true;
        });
      }
      final results = await Future.wait<dynamic>([
        if (metadataNeeded)
          debugTimed('Library bookmarks', repository.bookmarks)
        else
          Future.value(bookmarks),
        debugTimed(
          'Library resources',
          () => repository.list(
            mine: mine,
            search: query,
            category: queryCategory,
            level: queryLevel,
            kind: queryKind,
            offset: offset,
          ),
        ),
      ]);
      final saved = results[0] as Set<String>;
      final rows = results[1] as List<LearningResource>;
      var hasMaterials = rows.isNotEmpty;
      final filtered =
          query.trim().isNotEmpty ||
          queryCategory != null ||
          queryLevel != null ||
          queryKind != null;
      if (!mentor && !hasMaterials && filtered) {
        final available = await repository.list(
          mine: false,
          search: '',
          offset: 0,
        );
        hasMaterials = available.isNotEmpty;
      }
      if (!valid()) return;
      update(() {
        _metadataUser = owner;
        bookmarks = saved;
        resources = append ? [...resources, ...rows] : rows;
        more = rows.length == 20;
        if (!append) hasAccessibleMaterials = hasMaterials;
      });
    } catch (e) {
      if (valid()) update(() => error = contentError(e));
    } finally {
      if (valid()) update(() => loading = false);
    }
  }
}
