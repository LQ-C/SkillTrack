import 'package:supabase_flutter/supabase_flutter.dart';

String friendlyError(Object error) {
  if (error is AuthException) {
    switch (error.code) {
      case 'invalid_credentials':
        return 'Email or password is incorrect.';
      case 'email_not_confirmed':
        return 'Verify your email before signing in. You can resend verification below.';
      case 'over_email_send_rate_limit':
      case 'over_request_rate_limit':
        return 'Too many requests. Please wait before trying again.';
      case 'weak_password':
        return 'Choose a stronger password with uppercase, lowercase, a number and a symbol.';
      default:
        return 'The account request could not be completed. Check your details and try again.';
    }
  }
  return 'Could not complete the request. Check your connection and try again. If it continues, check the Supabase setup.';
}
