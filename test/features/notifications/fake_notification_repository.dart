import 'package:skilltrack/features/notifications/models/app_notification.dart';
import 'package:skilltrack/features/notifications/models/notification_preferences.dart';
import 'package:skilltrack/features/notifications/repositories/notification_repository.dart';

class FakeNotificationRepository implements NotificationRepository {
  FakeNotificationRepository({this.currentUserId = 'user'});
  @override
  final String? currentUserId;
  final List<AppNotification> items = [];
  NotificationPreferences? savedPreferences;
  bool failLoad = false, failRead = false, failAll = false, failSave = false;
  int reads = 0;

  @override
  Future<List<AppNotification>> getNotifications({
    int limit = 50,
    DateTime? before,
  }) async {
    if (failLoad) throw StateError('load');
    final filtered =
        items
            .where(
              (item) =>
                  item.userId == currentUserId &&
                  (before == null || item.createdAt.isBefore(before)),
            )
            .toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return filtered.take(limit).toList();
  }

  @override
  Future<int> getUnreadCount() async => items
      .where((item) => item.userId == currentUserId && item.isUnread)
      .length;

  @override
  Future<AppNotification> createNotification(
    AppNotification notification,
  ) async {
    if (notification.uniqueKey != null &&
        await notificationExists(notification.uniqueKey!)) {
      throw StateError('duplicate');
    }
    final created = AppNotification.fromMap({
      ...notification.toMap(),
      'id': '${items.length + 1}',
    });
    items.add(created);
    return created;
  }

  @override
  Future<void> markAsRead(String notificationId) async {
    reads++;
    if (failRead) throw StateError('read');
    final index = items.indexWhere((item) => item.id == notificationId);
    if (index >= 0 && items[index].isUnread) {
      items[index] = items[index].copyWith(
        isRead: true,
        readAt: DateTime.now().toUtc(),
      );
    }
  }

  @override
  Future<void> markAllAsRead() async {
    if (failAll) throw StateError('all');
    for (var i = 0; i < items.length; i++) {
      if (items[i].userId == currentUserId && items[i].isUnread) {
        items[i] = items[i].copyWith(
          isRead: true,
          readAt: DateTime.now().toUtc(),
        );
      }
    }
  }

  @override
  Future<NotificationPreferences> getPreferences() async =>
      savedPreferences ??= NotificationPreferences.defaults(currentUserId!);

  @override
  Future<NotificationPreferences> updatePreferences(
    NotificationPreferences preferences,
  ) async {
    if (failSave) throw StateError('save');
    return savedPreferences = preferences;
  }

  @override
  Future<bool> notificationExists(String uniqueKey) async => items.any(
    (item) => item.userId == currentUserId && item.uniqueKey == uniqueKey,
  );
}
