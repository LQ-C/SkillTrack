abstract class ProfileRepository {
  Future<Map<String, dynamic>> loadProfile();
  Future<Map<String, dynamic>> saveProfile(
    String name,
    String birthDate,
    String role,
    String bio,
  );
}

/// Installation-local invalidation after a confirmed profile save. Consumers
/// re-read authorised data; this event is never proof of role or paid access.
abstract interface class ProfileChangeSource {
  String? get userId;
  Stream<String?> get userChanges;
  Stream<String> get profileChanges;
}
