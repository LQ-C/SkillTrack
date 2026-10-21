import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/errors/app_exception.dart';
import 'push_device_repository.dart';

class SupabasePushDeviceRepository implements PushDeviceRepository {
  SupabasePushDeviceRepository(this._client);
  final SupabaseClient _client;

  @override
  String? get currentUserId => _client.auth.currentUser?.id;

  Future<void> _invoke(String function, String token) async {
    try {
      if (currentUserId == null) {
        throw const AppException('Sign in to manage push notifications.');
      }
      await _client.rpc(
        function,
        params: {
          'p_fcm_token': token,
          if (function == 'register_project_push_device')
            'p_platform': 'android',
        },
      );
    } on AppException {
      rethrow;
    } catch (_) {
      throw const AppException(
        'Unable to update this device’s push registration.',
      );
    }
  }

  @override
  Future<void> register(String token) =>
      _invoke('register_project_push_device', token);

  @override
  Future<void> unregister(String token) =>
      _invoke('unregister_project_push_device', token);
}
