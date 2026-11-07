import '../errors/app_exception.dart';
import 'operation_id.dart';

/// Retains an uncertain write's original arguments for this ViewModel's lifetime.
class RetryableWrite<T> {
  final Map<Object, _WriteAttempt<T>> _pending = {};

  bool contains(Object intent) => _pending.containsKey(intent);

  Future<T> run(Object intent, Future<T> Function(String) send) async {
    final attempt = _pending.putIfAbsent(
      intent,
      () => _WriteAttempt<T>(createOperationId(), send),
    );
    try {
      final result = await attempt.send(attempt.id);
      _pending.remove(intent);
      return result;
    } on AppException catch (error) {
      // A version conflict means the server did not commit this request.
      if (error.message == AppErrorMessages.taskChanged) {
        _pending.remove(intent);
      }
      rethrow;
    }
  }
}

class _WriteAttempt<T> {
  const _WriteAttempt(this.id, this.send);

  final String id;
  final Future<T> Function(String) send;
}
