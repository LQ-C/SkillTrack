import 'package:flutter/material.dart';

import '../features/kanban/repositories/kanban_repository.dart';
import '../features/projects/repositories/project_repository.dart';
import '../features/notifications/repositories/notification_repository.dart';
import '../features/notifications/viewmodels/notification_badge_controller.dart';
import 'app_theme.dart';
import 'router/app_router.dart';

class SkillTrackApp extends StatefulWidget {
  const SkillTrackApp({
    super.key,
    required this.projectRepository,
    required this.kanbanRepository,
    this.notificationRepository,
  });
  final ProjectRepository projectRepository;
  final KanbanRepository kanbanRepository;
  final NotificationRepository? notificationRepository;
  @override
  State<SkillTrackApp> createState() => _SkillTrackAppState();
}

class _SkillTrackAppState extends State<SkillTrackApp>
    with WidgetsBindingObserver {
  late final NotificationBadgeController _badge = NotificationBadgeController(
    widget.notificationRepository,
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _badge.refresh();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _badge.refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _badge.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final router = AppRouter(
      projectRepository: widget.projectRepository,
      kanbanRepository: widget.kanbanRepository,
      notificationRepository: widget.notificationRepository,
      badgeController: _badge,
    );
    return MaterialApp(
      title: 'SkillTrack',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      initialRoute: AppRoutes.projectDashboard,
      onGenerateInitialRoutes: (_) => [
        router.onGenerateRoute(
          const RouteSettings(name: AppRoutes.projectDashboard),
        ),
      ],
      onGenerateRoute: router.onGenerateRoute,
    );
  }
}
