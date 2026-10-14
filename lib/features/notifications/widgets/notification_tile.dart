import 'package:flutter/material.dart';

import '../models/app_notification.dart';
import '../models/notification_type.dart';

class NotificationTile extends StatelessWidget {
  const NotificationTile({
    super.key,
    required this.notification,
    required this.onTap,
  });
  final AppNotification notification;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final local = notification.createdAt.toLocal();
    final date = MaterialLocalizations.of(context).formatMediumDate(local);
    final time = MaterialLocalizations.of(
      context,
    ).formatTimeOfDay(TimeOfDay.fromDateTime(local));
    final icon = switch (notification.type) {
      NotificationType.stalledTask => Icons.timer_off_outlined,
      NotificationType.deadlineReminder => Icons.event_outlined,
      NotificationType.learningResourceRecommendation =>
        Icons.menu_book_outlined,
      NotificationType.unknown => Icons.notifications_none,
    };
    return Semantics(
      label:
          '${notification.isUnread ? 'Unread. ' : ''}${notification.title}. '
          '${notification.message}. $date at $time',
      button: true,
      child: Card(
        color: notification.isUnread
            ? theme.colorScheme.primaryContainer.withValues(alpha: .4)
            : theme.colorScheme.surface,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(child: Icon(icon)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        notification.title,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: notification.isUnread
                              ? FontWeight.w700
                              : FontWeight.w400,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(notification.message),
                      const SizedBox(height: 8),
                      Text('$date · $time', style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
                if (notification.isUnread)
                  Padding(
                    padding: const EdgeInsets.only(top: 8, right: 4),
                    child: Container(
                      key: const Key('unread-dot'),
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                if (notification.canNavigate) const Icon(Icons.chevron_right),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
