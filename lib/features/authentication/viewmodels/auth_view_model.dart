import 'package:skilltrack/core/utils/view_model.dart';
import 'package:skilltrack/core/errors/auth_errors.dart';
import '../repositories/account_repository.dart';
import '../models/auth_registration.dart';
import '../models/mentor_registration.dart';

class AuthViewModel extends ViewModel {
  AuthViewModel(this.repository);
  final AccountRepository repository;
  bool busy = false, error = false;
  String? message;
  Future<void> perform(Future<String?> Function() operation) async {
    if (busy) return;
    update(() {
      busy = true;
      message = null;
      error = false;
    });
    try {
      final result = await operation();
      update(() => message = result);
    } catch (e) {
      update(() {
        error = true;
        message = friendlyError(e);
      });
    } finally {
      update(() => busy = false);
    }
  }

  Future<void> signIn(String email, String password) =>
      repository.signIn(email, password);
  Future<AuthRegistration> register({
    required String email,
    required String password,
    required String name,
    required String birthDate,
    required String role,
    MentorRegistration? mentorApplication,
  }) => repository.register(
    email: email,
    password: password,
    name: name,
    birthDate: birthDate,
    role: role,
    mentorApplication: mentorApplication,
  );
  Future<void> sendEmail(String email, {required bool reset}) => reset
      ? repository.sendPasswordReset(email)
      : repository.resendVerification(email);
  Future<void> recoverPassword(String password) async {
    await repository.updatePassword(password);
    await repository.signOut();
  }
}
