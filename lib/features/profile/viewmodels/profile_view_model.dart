import 'dart:async';
import 'package:skilltrack/core/utils/view_model.dart';
import 'package:skilltrack/core/errors/auth_errors.dart';
import 'package:skilltrack/features/authentication/repositories/account_repository.dart';
import '../models/user_profile.dart';
import '../repositories/profile_repository.dart';

class ProfileViewModel extends ViewModel {
  ProfileViewModel(this.repository, this.accounts) {
    if (repository is ProfileChangeSource) {
      _source = repository as ProfileChangeSource;
      _owner = _source!.userId;
      _session = _source!.userChanges.listen((user) {
        if (!isActive || user == _owner) return;
        _owner = user;
        _generation++;
        update(() {
          profile = null;
          loading = false;
          busy = false;
          message = null;
          error = false;
        });
      });
    }
  }
  ProfileChangeSource? _source;
  String? _owner;
  int _generation = 0;
  StreamSubscription<String?>? _session;
  bool _current(int generation) =>
      isActive &&
      generation == _generation &&
      (_source == null || (_owner != null && _source!.userId == _owner));
  final ProfileRepository repository;
  final AccountRepository accounts;
  UserProfile? profile;
  bool loading = true, busy = false, error = false;
  bool get loaded => profile != null;
  String? message;
  Future<UserProfile?> load() async {
    final generation = _generation;
    if (!_current(generation)) return null;
    update(() {
      loading = true;
      message = null;
      error = false;
    });
    try {
      final value = UserProfile.fromJson(await repository.loadProfile());
      if (!_current(generation)) return null;
      update(() => profile = value);
      return value;
    } catch (e) {
      if (!_current(generation)) return null;
      update(() {
        error = true;
        message = friendlyError(e);
      });
      return null;
    } finally {
      if (_current(generation)) update(() => loading = false);
    }
  }

  Future<void> run(Future<void> Function() action, String success) async {
    final generation = _generation;
    if (busy || !_current(generation)) return;
    update(() {
      busy = true;
      message = null;
      error = false;
    });
    try {
      await action();
      if (_current(generation)) update(() => message = success);
    } catch (e) {
      if (!_current(generation)) return;
      update(() {
        error = true;
        message = friendlyError(e);
      });
    } finally {
      if (_current(generation)) update(() => busy = false);
    }
  }

  Future<void> save(String name, String birthDate, String role, String bio) {
    final generation = _generation;
    return run(() async {
      final row = await repository.saveProfile(name, birthDate, role, bio);
      if (_current(generation)) {
        update(() => profile = UserProfile.fromJson(row));
      }
    }, 'Your profile has been saved.');
  }

  Future<void> secureAction(bool delete, String password, String replacement) =>
      run(
        () => delete
            ? accounts.deleteAccount(password)
            : accounts.changePassword(password, replacement),
        delete ? 'Account deleted.' : 'Your password has been updated.',
      );
  Future<void> signOut() => run(accounts.signOut, 'Signed out.');

  @override
  void dispose() {
    _generation++;
    _session?.cancel();
    super.dispose();
  }
}
