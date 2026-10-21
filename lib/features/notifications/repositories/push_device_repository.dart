abstract interface class PushDeviceRepository {
  String? get currentUserId;
  Future<void> register(String token);
  Future<void> unregister(String token);
}
