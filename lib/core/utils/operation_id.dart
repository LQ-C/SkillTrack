import 'dart:convert';
import 'dart:math';

/// Stable for one save attempt and its retries; never an ownership credential.
String createOperationId() {
  final random = Random.secure();
  return base64UrlEncode(List.generate(16, (_) => random.nextInt(256)));
}
