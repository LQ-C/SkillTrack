import 'package:supabase_flutter/supabase_flutter.dart';
import '../features/authentication/services/account_service.dart';
import '../features/educational_content/repositories/content_repository.dart';
import '../features/educational_content/repositories/supabase_content_repository.dart';
import '../features/tutor_management/repositories/tutor_repository.dart';
import '../features/tutor_management/repositories/supabase_tutor_repository.dart';

class MarketplaceDependencies {
  MarketplaceDependencies(SupabaseClient client)
    : accounts = AccountService(client),
      content = SupabaseContentRepository(client),
      tutors = SupabaseTutorRepository(client);
  MarketplaceDependencies.inject({
    required this.accounts,
    required this.content,
    required this.tutors,
  });
  final AccountService accounts;
  final ContentRepository content;
  final TutorRepository tutors;
}
