import 'package:supabase_flutter/supabase_flutter.dart';

String contentError(Object error) {
  if (error is PostgrestException) {
    if (['PGRST205', '42P01', 'PGRST202', '404'].contains(error.code)) {
      return 'Learning resources are not set up yet. Run the educational content SQL setup in Supabase, then tap Retry.';
    }
    if (error.code == '23505') {
      return 'You have already submitted a report for this resource.';
    }
    if (error.code == '42501') {
      return 'This action is not allowed. Check your mentor approval or sign in again.';
    }
    if (error.code == 'PGRST116') {
      return 'This resource is no longer available. Refresh the library.';
    }
    if (error.code == '23514') {
      return 'Check the resource fields and try again.';
    }
    return 'The learning database request failed (code: ${error.code ?? 'unknown'}). Share this code so the setup can be checked.';
  }
  return 'Could not complete the request. Check your connection and try again.';
}
