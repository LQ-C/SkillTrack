import 'package:supabase_flutter/supabase_flutter.dart';
import '../repositories/profile_repository.dart';

class ProfileService implements ProfileRepository {
  ProfileService(this.client);
  final SupabaseClient client;
  @override
  Future<Map<String, dynamic>> loadProfile() async => await client
      .from('profiles')
      .select()
      .eq('id', client.auth.currentUser!.id)
      .single();
  @override
  Future<void> saveProfile(
    String name,
    String birthDate,
    String role,
    String bio,
  ) async {
    await client
        .from('profiles')
        .update({
          'full_name': name.trim(),
          'date_of_birth': birthDate,
          'role': role,
          'bio': bio.trim(),
        })
        .eq('id', client.auth.currentUser!.id)
        .select()
        .single();
  }
}
