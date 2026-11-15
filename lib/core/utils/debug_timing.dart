import 'package:flutter/foundation.dart';

/// Labels must be constant operation names, never user data or URLs.
Future<T> debugTimed<T>(String label, Future<T> Function() action) async {
  if (!kDebugMode) return action();
  final timer = Stopwatch()..start();
  try {
    return await action();
  } finally {
    debugPrint('[Loading] $label: ${timer.elapsedMilliseconds} ms');
  }
}
