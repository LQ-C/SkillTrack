import 'package:flutter/material.dart';

import '../../../app/app_theme.dart';

import '../models/app_notification.dart';
import '../models/notification_type.dart';

class NotificationTile extends StatelessWidget {
  const NotificationTile({
    super.key,
    required this.notification,
    required this.onTap,
  });
  final AppNotification notification;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final accent = switch (notification.type) {
      NotificationType.stalledTask => scheme.tertiary,
      NotificationType.deadlineReminder => scheme.primary,
      NotificationType.learningResourceRecommendation => scheme.secondary,
      NotificationType.unknown => scheme.onSurfaceVariant,
    };
    final accentContainer = switch (notification.type) {
      NotificationType.stalledTask => scheme.tertiaryContainer,
      NotificationType.deadlineReminder => scheme.primaryContainer,
      NotificationType.learningResourceRecommendation =>
        scheme.secondaryContainer,
      NotificationType.unknown => scheme.surfaceContainerHighest,
    };
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
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: AnimatedContainer(
          duration: AppTheme.motionDuration(context),
          curve: AppTheme.transitionCurve,
          decoration: BoxDecoration(
            borderRadius: AppTheme.cardRadius,
            border: Border.all(
              color: notification.isUnread
                  ? accent.withValues(alpha: .22)
                  : scheme.outlineVariant.withValues(alpha: .65),
            ),
            color: notification.isUnread
                ? Color.alphaBlend(
                    accent.withValues(alpha: .055),
                    scheme.surface,
                  )
                : scheme.surface,
          ),
          child: Card(
            margin: EdgeInsets.zero,
            elevation: 0,
            color: Colors.transparent,
            shape: const RoundedRectangleBorder(
              borderRadius: AppTheme.cardRadius,
            ),
            child: InkWell(
              onTap: onTap,
              borderRadius: AppTheme.cardRadius,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CircleAvatar(
                      backgroundColor: accentContainer,
                      foregroundColor: accent,
                      child: Icon(icon),
                    ),
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
                                  : FontWeight.w500,
                              color: scheme.onSurface,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            notification.message,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '$date · $time',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
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
                            color: accent,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                    if (notification.canNavigate)
                      Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
