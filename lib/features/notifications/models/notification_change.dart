import 'app_notification.dart';

enum NotificationChangeType { inserted, updated, deleted, reset }

class NotificationChange {
  const NotificationChange({
    required this.type,
    required this.userId,
    required this.notificationId,
    this.notification,
  });

  final NotificationChangeType type;
  final String userId;
  final String notificationId;
  final AppNotification? notification;
}
