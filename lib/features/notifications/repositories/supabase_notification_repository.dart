import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/errors/app_exception.dart';
import '../models/app_notification.dart';
import '../models/notification_preferences.dart';
import 'notification_repository.dart';

class SupabaseNotificationRepository implements NotificationRepository {
  SupabaseNotificationRepository(this._client);
  final SupabaseClient _client;

  @override
  String? get currentUserId => _client.auth.currentUser?.id;

  String get _userId =>
      currentUserId ??
      (throw const AppException('Sign in to view notifications.'));

  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on AppException {
      rethrow;
    } catch (_) {
      throw const AppException(
        'Unable to update notifications. Please try again.',
      );
    }
  }

  @override
  Future<List<AppNotification>> getNotifications({
    int limit = 50,
    DateTime? before,
  }) => _guard(() async {
    final userId = _userId;
    var query = _client.from('notifications').select().eq('user_id', userId);
    if (before != null) {
      query = query.lt('created_at', before.toUtc().toIso8601String());
    }
    final rows = await query.order('created_at', ascending: false).limit(limit);
    return rows.map(AppNotification.fromMap).toList();
  });

  @override
  Future<int> getUnreadCount() => _guard(() async {
    final result = await _client
        .from('notifications')
        .select('id')
        .eq('user_id', _userId)
        .eq('is_read', false)
        .count(CountOption.exact);
    return result.count;
  });

  @override
  Future<AppNotification> createNotification(AppNotification notification) =>
      _guard(() async {
        if (notification.userId != _userId) {
          throw const AppException(
            'Unable to create a notification for this account.',
          );
        }
        final data = notification.toMap()..remove('id');
        final row = await _client
            .from('notifications')
            .insert(data)
            .select()
            .single();
        return AppNotification.fromMap(row);
      });

  @override
  Future<void> markAsRead(String notificationId) => _guard(() async {
    await _client
        .from('notifications')
        .update({
          'is_read': true,
          'read_at': DateTime.now().toUtc().toIso8601String(),
        })
        .eq('id', notificationId)
        .eq('user_id', _userId)
        .eq('is_read', false);
  });

  @override
  Future<void> markAllAsRead() => _guard(() async {
    await _client
        .from('notifications')
        .update({
          'is_read': true,
          'read_at': DateTime.now().toUtc().toIso8601String(),
        })
        .eq('user_id', _userId)
        .eq('is_read', false);
  });

  @override
  Future<NotificationPreferences> getPreferences() => _guard(() async {
    final userId = _userId;
    final row = await _client
        .from('notification_preferences')
        .select()
        .eq('user_id', userId)
        .maybeSingle();
    if (row != null) return NotificationPreferences.fromMap(row);
    try {
      await _client
          .from('notification_preferences')
          .insert(NotificationPreferences.defaults(userId).toMap());
    } on PostgrestException catch (error) {
      if (error.code != '23505') rethrow;
    }
    final created = await _client
        .from('notification_preferences')
        .select()
        .eq('user_id', userId)
        .single();
    return NotificationPreferences.fromMap(created);
  });

  @override
  Future<NotificationPreferences> updatePreferences(
    NotificationPreferences preferences,
  ) => _guard(() async {
    if (preferences.userId != _userId) {
      throw const AppException('Unable to save these preferences.');
    }
    final row = await _client
        .from('notification_preferences')
        .upsert(preferences.toMap(), onConflict: 'user_id')
        .select()
        .single();
    return NotificationPreferences.fromMap(row);
  });

  @override
  Future<bool> notificationExists(String uniqueKey) => _guard(() async {
    final row = await _client
        .from('notifications')
        .select('id')
        .eq('user_id', _userId)
        .eq('unique_key', uniqueKey)
        .maybeSingle();
    return row != null;
  });
}
