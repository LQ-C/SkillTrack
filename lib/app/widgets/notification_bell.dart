import 'package:flutter/material.dart';
import '../router/app_router.dart';
import '../../features/notifications/viewmodels/notification_badge_controller.dart';

class NotificationBellScope extends InheritedWidget {
  const NotificationBellScope({
    super.key,
    required this.controller,
    required super.child,
  });
  final NotificationBadgeController controller;
  @override
  bool updateShouldNotify(NotificationBellScope oldWidget) =>
      controller != oldWidget.controller;
}

class NotificationBell extends StatefulWidget {
  const NotificationBell({super.key});
  @override
  State<NotificationBell> createState() => _NotificationBellState();
}

class _NotificationBellState extends State<NotificationBell> {
  bool opening = false;
  @override
  Widget build(BuildContext context) {
    final controller = context
        .dependOnInheritedWidgetOfExactType<NotificationBellScope>()
        ?.controller;
    if (controller == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => IconButton(
        tooltip: 'Notifications',
        onPressed: opening
            ? null
            : () async {
                if (opening) return;
                setState(() => opening = true);
                try {
                  await AppRouter.notifications(context);
                } finally {
                  if (mounted) setState(() => opening = false);
                }
              },
        icon: Badge(
          isLabelVisible: controller.unreadCount > 0,
          label: Text(
            controller.unreadCount > 99 ? '99+' : '${controller.unreadCount}',
          ),
          child: const Icon(Icons.notifications_outlined),
        ),
      ),
    );
  }
}
