import 'package:skilltrack/core/utils/view_model.dart';
import 'package:skilltrack/core/errors/auth_errors.dart';
import 'package:skilltrack/features/authentication/repositories/account_repository.dart';
import '../models/user_profile.dart';
import '../repositories/profile_repository.dart';

class ProfileViewModel extends ViewModel {
  ProfileViewModel(this.repository, this.accounts);
  final ProfileRepository repository;
  final AccountRepository accounts;
  UserProfile? profile;
  bool loading = true, busy = false, error = false;
  bool get loaded => profile != null;
  String? message;
  Future<UserProfile?> load() async {
    update(() {
      loading = true;
      message = null;
      error = false;
    });
    try {
      final value = UserProfile.fromJson(await repository.loadProfile());
      update(() => profile = value);
      return value;
    } catch (e) {
      update(() {
        error = true;
        message = friendlyError(e);
      });
      return null;
    } finally {
      update(() => loading = false);
    }
  }

  Future<void> run(Future<void> Function() action, String success) async {
    if (busy) return;
    update(() {
      busy = true;
      message = null;
      error = false;
    });
    try {
      await action();
      update(() => message = success);
    } catch (e) {
      update(() {
        error = true;
        message = friendlyError(e);
      });
    } finally {
      update(() => busy = false);
    }
  }

  Future<void> save(String name, String birthDate, String role, String bio) =>
      run(
        () => repository.saveProfile(name, birthDate, role, bio),
        'Your profile has been saved.',
      );
  Future<void> secureAction(bool delete, String password, String replacement) =>
      run(
        () => delete
            ? accounts.deleteAccount(password)
            : accounts.changePassword(password, replacement),
        delete ? 'Account deleted.' : 'Your password has been updated.',
      );
  Future<void> signOut() => run(accounts.signOut, 'Signed out.');
}
