import 'package:flutter/material.dart';
import '../../features/notifications/viewmodels/notification_list_view_model.dart';
import '../../features/notifications/views/notification_screen.dart';
import '../router/app_router.dart';

class NotificationRoute extends StatefulWidget {
  const NotificationRoute({
    super.key,
    required this.router,
    this.notificationId,
  });
  final AppRouter router;
  final String? notificationId;
  @override
  State<NotificationRoute> createState() => _NotificationRouteState();
}

class _NotificationRouteState extends State<NotificationRoute> {
  late final model = NotificationListViewModel(
    widget.router.notificationRepository!,
    widget.router.projectRepository,
    widget.router.kanbanRepository,
    widget.router.badgeController!,
    widget.router.realtime,
  );
  @override
  void dispose() {
    model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => NotificationScreen(
    viewModel: model,
    initialNotificationId: widget.notificationId,
    badgeController: widget.router.badgeController!,
    showBottomNavigation: false,
    onOpenProjectDashboard: () =>
        Navigator.of(context).popUntil((r) => r.isFirst),
  );
}
