import '../models/app_notification.dart';
import '../models/notification_preferences.dart';

abstract class NotificationRepository {
  String? get currentUserId;
  Future<List<AppNotification>> getNotifications({
    int limit = 50,
    DateTime? before,
    String? beforeId,
  });
  Future<AppNotification?> getNotification(String id);
  Future<int> getUnreadCount();
  Future<void> markAsRead(String notificationId);
  Future<void> markAllAsRead();
  Future<NotificationPreferences> getPreferences();
  Future<NotificationPreferences> updatePreferences(
    NotificationPreferences preferences,
  );
}
