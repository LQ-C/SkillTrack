import 'package:skilltrack/features/profile/services/profile_service.dart';
import 'package:skilltrack/features/profile/repositories/profile_repository.dart';
import 'package:skilltrack/features/authentication/models/auth_registration.dart';
import 'package:skilltrack/features/authentication/repositories/account_repository.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/mentor_registration.dart';

class AccountService implements AccountRepository, ProfileRepository {
  AccountService([this._client]);
  final SupabaseClient? _client;
  SupabaseClient get client => _client ?? Supabase.instance.client;
  String get redirect => kIsWeb
      ? Uri.base.replace(fragment: '', query: '').toString()
      : 'com.skilltrack.app://login-callback/';

  @override
  Future<void> signIn(String email, String password) async {
    final timer = Stopwatch()..start();
    try {
      await client.auth.signInWithPassword(
        email: email.trim(),
        password: password,
      );
    } finally {
      if (kDebugMode) {
        debugPrint(
          '[Loading] Sign-in request: ${timer.elapsedMilliseconds} ms',
        );
      }
    }
  }

  @override
  Future<AuthRegistration> register({
    required String email,
    required String password,
    required String name,
    required String birthDate,
    required String role,
    MentorRegistration? mentorApplication,
  }) async {
    final response = await client.auth.signUp(
      email: email.trim(),
      password: password,
      emailRedirectTo: redirect,
      data: {
        'full_name': name.trim(),
        'date_of_birth': birthDate,
        'role': role,
      },
    );
    return AuthRegistration(verificationRequired: response.session == null);
  }

  @override
  String? get email => client.auth.currentUser?.email;
  @override
  bool get emailVerified => client.auth.currentUser?.emailConfirmedAt != null;
  @override
  Future<void> sendPasswordReset(String email) =>
      client.auth.resetPasswordForEmail(email.trim(), redirectTo: redirect);
  @override
  Future<void> resendVerification(String email) => client.auth.resend(
    type: OtpType.signup,
    email: email.trim(),
    emailRedirectTo: redirect,
  );
  @override
  Future<void> updatePassword(String password) async {
    await client.auth.updateUser(UserAttributes(password: password));
  }

  @override
  Future<void> signOut() => client.auth.signOut();
  @override
  Future<Map<String, dynamic>> loadProfile() =>
      ProfileService(client).loadProfile();
  @override
  Future<void> saveProfile(
    String name,
    String birthDate,
    String role,
    String bio,
  ) => ProfileService(client).saveProfile(name, birthDate, role, bio);

  @override
  Future<void> changePassword(String current, String replacement) async {
    await signIn(client.auth.currentUser!.email!, current);
    await client.auth.updateUser(UserAttributes(password: replacement));
  }

  @override
  Future<void> deleteAccount(String password) async {
    final response = await client.functions.invoke(
      'delete-account',
      body: {'password': password},
    );
    if (response.status != 200) {
      throw const AuthException('Account deletion failed.');
    }
    await client.auth.signOut(scope: SignOutScope.local);
  }
}
