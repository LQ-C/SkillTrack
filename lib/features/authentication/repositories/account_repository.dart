import '../models/auth_registration.dart';
import '../models/mentor_registration.dart';

abstract class AccountRepository {
  String? get email;
  bool get emailVerified;
  Future<void> signIn(String email, String password);
  Future<AuthRegistration> register({
    required String email,
    required String password,
    required String name,
    required String birthDate,
    required String role,
    MentorRegistration? mentorApplication,
  });
  Future<void> sendPasswordReset(String email);
  Future<void> resendVerification(String email);
  Future<void> updatePassword(String password);
  Future<void> signOut();
  Future<void> changePassword(String current, String replacement);
  Future<void> deleteAccount(String password);
}
