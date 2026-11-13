abstract class ProfileRepository {
  Future<Map<String, dynamic>> loadProfile();
  Future<void> saveProfile(
    String name,
    String birthDate,
    String role,
    String bio,
  );
}
