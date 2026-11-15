import '../../profile/repositories/profile_repository.dart';
import 'dart:async';
import '../../../core/utils/view_model.dart';
import '../../../core/utils/debug_timing.dart';
import '../models/tutor_models.dart';
import '../repositories/tutor_repository.dart';
import 'tutor_view_model.dart';

class ExploreMentorsViewModel extends ViewModel {
  ExploreMentorsViewModel(
    this.repository, {
    ProfileChangeSource? profiles,
    this.requestTimeout = const Duration(seconds: 20),
  }) : _owner = repository.userId {
    _profileChanges = profiles?.profileChanges.listen((user) {
      if (!current || user != _owner || profiles.userId != user) return;
      _reset();
      unawaited(load());
    });
    if (repository is TutorSessionSource) {
      _session = (repository as TutorSessionSource).userChanges.listen((user) {
        if (!isActive || user == _owner) return;
        _owner = user;
        _reset();
        if (user != null) unawaited(load());
      });
    }
  }
  void _reset() {
    _version++;
    _pending = null;
    update(() {
      role = null;
      mentors = [];
      ownProfile = null;
      hasLoaded = false;
      loading = false;
      error = null;
    });
  }

  StreamSubscription<String>? _profileChanges;
  final TutorRepository repository;
  final Duration requestTimeout;
  String? _owner;
  StreamSubscription<String?>? _session;
  Future<void>? _pending;
  int _version = 0;
  String? role, error;
  String query = '';
  bool loading = true, hasLoaded = false;
  List<Mentor> mentors = [];
  TutorProfile? ownProfile;
  bool get current {
    try {
      return isActive && _owner != null && repository.userId == _owner;
    } catch (_) {
      return false;
    }
  }

  List<Mentor> get matches => mentors
      .where(
        (m) => '${m.name} ${m.headline} ${m.expertise}'.toLowerCase().contains(
          query.trim().toLowerCase(),
        ),
      )
      .toList();
  void search(String value) => update(() => query = value);
  Future<void> load() {
    if (!current) return Future.value();
    if (_pending != null) return _pending!;
    late final Future<void> request;
    request = _load().whenComplete(() {
      if (identical(request, _pending)) _pending = null;
    });
    return _pending = request;
  }

  Future<void> _load() async {
    final version = ++_version;
    bool valid() => current && version == _version;
    var stage = 'account role';
    update(() {
      loading = true;
      error = null;
    });
    try {
      final accountRole = await debugTimed(
        'Explore account role',
        () => repository.role().timeout(requestTimeout),
      );
      if (!valid()) return;
      if (role != accountRole) {
        update(() {
          role = accountRole;
          mentors = [];
          ownProfile = null;
          hasLoaded = false;
        });
      }
      if (accountRole == 'student') {
        stage = 'mentor directory';
        final items = await debugTimed(
          'Explore mentor directory',
          () => repository.directory().timeout(requestTimeout),
        );
        if (!valid()) return;
        update(() => mentors = items);
      } else if (accountRole == 'mentor') {
        stage = 'mentor profile';
        final profile = await debugTimed(
          'Explore own profile',
          () => repository.profile().timeout(requestTimeout),
        );
        if (!valid()) return;
        update(() => ownProfile = profile);
      }
      if (valid()) update(() => hasLoaded = true);
    } catch (e) {
      if (valid()) {
        update(
          () => error = e is TimeoutException
              ? 'Loading $stage timed out. Please retry.'
              : tutorError(e),
        );
      }
    } finally {
      if (valid()) update(() => loading = false);
    }
  }

  /// Recheck role before any authoring action; cached display state is not authority.
  Future<TutorProfile?> prepareProfileEditor() async {
    final version = _version;
    final owner = _owner;
    bool valid() => current && version == _version && owner == _owner;
    if (!valid()) return null;
    final accountRole = await debugTimed(
      'Explore authoring role',
      () => repository.role().timeout(requestTimeout),
    );
    if (!valid()) return null;
    if (accountRole != 'mentor') {
      await load();
      return null;
    }
    if (ownProfile == null) {
      await repository.enable().timeout(requestTimeout);
    }
    if (!valid()) return null;
    final profile = await repository.profile().timeout(requestTimeout);
    if (!valid()) return null;
    if (profile == null) {
      throw const FormatException(
        'Could not create your mentor profile. Try again.',
      );
    }
    return profile;
  }

  @override
  void dispose() {
    _version++;
    _session?.cancel();
    _profileChanges?.cancel();
    super.dispose();
  }
}
