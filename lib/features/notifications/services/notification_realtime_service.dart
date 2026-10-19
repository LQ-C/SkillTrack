import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/app_notification.dart';
import '../models/notification_change.dart';

abstract class NotificationChangeSource {
  String? get activeUserId;
  bool get isConnected;
  Stream<NotificationChange> get changes;
  Stream<void> get syncRequests;
  Future<void> startForUser(String userId);
  Future<void> stop();
  void requestSync();
}

abstract class NotificationRealtimeTransport {
  Future<void> subscribeForUser(
    String userId,
    void Function(PostgresChangePayload) onPayload,
    void Function(RealtimeSubscribeStatus) onStatus,
  );
  Future<void> unsubscribe();
}

class SupabaseNotificationRealtimeTransport
    implements NotificationRealtimeTransport {
  SupabaseNotificationRealtimeTransport(this._client);

  final SupabaseClient _client;
  RealtimeChannel? _channel;

  @override
  Future<void> subscribeForUser(
    String userId,
    void Function(PostgresChangePayload) onPayload,
    void Function(RealtimeSubscribeStatus) onStatus,
  ) async {
    final ready = Completer<void>();
    _channel = _client
        .channel('user-notifications-$userId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'notifications',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: userId,
          ),
          callback: onPayload,
        )
        .subscribe((status, _) {
          onStatus(status);
          if (ready.isCompleted) return;
          switch (status) {
            case RealtimeSubscribeStatus.subscribed:
              ready.complete();
            case RealtimeSubscribeStatus.channelError:
            case RealtimeSubscribeStatus.timedOut:
            case RealtimeSubscribeStatus.closed:
              ready.completeError(
                StateError('Notification Realtime unavailable'),
              );
          }
        });
    try {
      await ready.future.timeout(const Duration(seconds: 25));
    } catch (_) {
      await unsubscribe();
      rethrow;
    }
  }

  @override
  Future<void> unsubscribe() async {
    final channel = _channel;
    _channel = null;
    if (channel != null) await _client.removeChannel(channel);
  }
}

class NotificationRealtimeService implements NotificationChangeSource {
  NotificationRealtimeService(this._transport);

  final NotificationRealtimeTransport _transport;
  final _changes = StreamController<NotificationChange>.broadcast();
  final _syncRequests = StreamController<void>.broadcast();
  Future<void> _pending = Future<void>.value();
  String? _activeUserId;
  bool _connected = false;
  bool _disposed = false;
  int _generation = 0;

  @override
  String? get activeUserId => _activeUserId;
  @override
  bool get isConnected => _connected;
  @override
  Stream<NotificationChange> get changes => _changes.stream;
  @override
  Stream<void> get syncRequests => _syncRequests.stream;

  @override
  Future<void> startForUser(String userId) {
    final operation = _pending.then((_) => _start(userId));
    _pending = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> _start(String userId) async {
    if (_disposed || userId.isEmpty) return;
    if (_activeUserId == userId && _connected) return;
    if (_activeUserId == userId) {
      try {
        await _transport.unsubscribe();
      } catch (_) {
        debugPrint('Notification Realtime cleanup failed');
      }
    } else if (_activeUserId != null) {
      await _stop();
    }
    final generation = ++_generation;
    _activeUserId = userId;
    var wasSubscribed = false;
    debugPrint('Notification Realtime subscribing');
    try {
      await _transport.subscribeForUser(
        userId,
        (payload) {
          if (_disposed ||
              generation != _generation ||
              _activeUserId != userId) {
            return;
          }
          final change = _parse(payload, userId);
          if (change != null) _changes.add(change);
        },
        (status) {
          if (generation != _generation) return;
          final wasConnected = _connected;
          _connected = status == RealtimeSubscribeStatus.subscribed;
          if (_connected) {
            wasSubscribed = true;
            if (!wasConnected) debugPrint('Notification Realtime subscribed');
          } else if (wasConnected) {
            debugPrint('Notification Realtime disconnected');
          }
          if (_connected && !wasConnected) requestSync();
          if (wasSubscribed &&
              (status == RealtimeSubscribeStatus.channelError ||
                  status == RealtimeSubscribeStatus.timedOut)) {
            debugPrint('Notification Realtime subscription failed');
          }
        },
      );
    } catch (_) {
      if (generation == _generation) {
        _connected = false;
        debugPrint('Notification Realtime subscription failed');
      }
    }
  }

  NotificationChange? _parse(PostgresChangePayload payload, String userId) {
    try {
      if (payload.eventType == PostgresChangeEvent.delete) {
        final id = payload.oldRecord['id']?.toString();
        final oldUser = payload.oldRecord['user_id']?.toString();
        if (oldUser != null && oldUser != userId) return null;
        if (id == null || id.isEmpty) {
          debugPrint('Ignored malformed notification Realtime event');
          return null;
        }
        return NotificationChange(
          type: NotificationChangeType.deleted,
          userId: userId,
          notificationId: id,
        );
      }
      final record = payload.newRecord;
      if (record['user_id']?.toString() != userId) return null;
      if (record['id']?.toString().isNotEmpty != true ||
          record['created_at']?.toString().isNotEmpty != true ||
          record['title'] == null ||
          record['message'] == null) {
        debugPrint('Ignored malformed notification Realtime event');
        return null;
      }
      if (payload.eventType != PostgresChangeEvent.insert &&
          payload.eventType != PostgresChangeEvent.update) {
        return null;
      }
      final notification = AppNotification.fromMap(record);
      return NotificationChange(
        type: payload.eventType == PostgresChangeEvent.insert
            ? NotificationChangeType.inserted
            : NotificationChangeType.updated,
        userId: userId,
        notificationId: notification.id,
        notification: notification,
      );
    } catch (_) {
      debugPrint('Ignored malformed notification Realtime event');
      return null;
    }
  }

  @override
  Future<void> stop() {
    final operation = _pending.then((_) => _stop());
    _pending = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> _stop() async {
    if (_activeUserId == null) return;
    ++_generation;
    _activeUserId = null;
    _connected = false;
    if (!_changes.isClosed) {
      _changes.add(
        const NotificationChange(
          type: NotificationChangeType.reset,
          userId: '',
          notificationId: '',
        ),
      );
    }
    try {
      await _transport.unsubscribe();
    } catch (_) {
      debugPrint('Notification Realtime cleanup failed');
    }
  }

  @override
  void requestSync() {
    if (!_syncRequests.isClosed && _activeUserId != null) {
      _syncRequests.add(null);
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await stop();
    await _changes.close();
    await _syncRequests.close();
  }
}
