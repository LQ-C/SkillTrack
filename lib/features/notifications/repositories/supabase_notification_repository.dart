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
      throw const AppException(AppErrorMessages.updateNotificationsFailed);
    }
  }

  @override
  Future<List<AppNotification>> getNotifications({
    int limit = 50,
    DateTime? before,
    String? beforeId,
  }) => _guard(() async {
    final userId = _userId;
    var query = _client.from('notifications').select().eq('user_id', userId);
    if (before != null) {
      final timestamp = before.toUtc().toIso8601String();
      if (beforeId == null) {
        query = query.lt('created_at', timestamp);
      } else {
        if (!RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(beforeId)) {
          throw const AppException(AppErrorMessages.invalidNotificationCursor);
        }
        query = query.or(
          'created_at.lt.$timestamp,and(created_at.eq.$timestamp,id.lt.$beforeId)',
        );
      }
    }
    final rows = await query
        .order('created_at', ascending: false)
        .order('id', ascending: false)
        .limit(limit);
    return rows.map(AppNotification.fromMap).toList();
  });

  @override
  Future<AppNotification?> getNotification(String id) => _guard(() async {
    final userId = _userId;
    final row = await _client
        .from('notifications')
        .select()
        .eq('id', id)
        .eq('user_id', userId)
        .maybeSingle();
    if (currentUserId != userId || row == null) return null;
    return AppNotification.fromMap(row);
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
}
