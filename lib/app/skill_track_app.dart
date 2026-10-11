import 'dart:async';

import 'package:flutter/material.dart';

import '../features/kanban/repositories/kanban_repository.dart';
import '../features/projects/repositories/project_repository.dart';
import '../features/notifications/repositories/notification_repository.dart';
import '../features/notifications/viewmodels/notification_badge_controller.dart';
import '../features/notifications/services/notification_realtime_service.dart';
import 'app_theme.dart';
import 'router/app_router.dart';

class SkillTrackApp extends StatefulWidget {
  const SkillTrackApp({
    super.key,
    required this.projectRepository,
    required this.kanbanRepository,
    this.notificationRepository,
    this.realtimeService,
    this.authEvents,
  });
  final ProjectRepository projectRepository;
  final KanbanRepository kanbanRepository;
  final NotificationRepository? notificationRepository;
  final NotificationRealtimeService? realtimeService;
  final Stream<Object?>? authEvents;
  @override
  State<SkillTrackApp> createState() => _SkillTrackAppState();
}

class _SkillTrackAppState extends State<SkillTrackApp>
    with WidgetsBindingObserver {
  late final NotificationBadgeController _badge = NotificationBadgeController(
    widget.notificationRepository,
    widget.realtimeService,
  );
  StreamSubscription<Object?>? _authSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _authSubscription = widget.authEvents?.listen((_) {
      unawaited(_syncSession());
    });
    unawaited(_syncSession());
  }

  Future<void> _syncSession({bool resumed = false}) async {
    final userId = widget.notificationRepository?.currentUserId;
    if (userId == null) {
      await widget.realtimeService?.stop();
      if (mounted) _badge.clear();
      return;
    }
    await widget.realtimeService?.startForUser(userId);
    if (!mounted || widget.notificationRepository?.currentUserId != userId) {
      return;
    }
    await _badge.startForUser(userId);
    if (!mounted || widget.notificationRepository?.currentUserId != userId) {
      return;
    }
    if (resumed) {
      if (widget.realtimeService == null) {
        await _badge.refresh();
      } else {
        widget.realtimeService!.requestSync();
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_syncSession(resumed: true));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _authSubscription?.cancel();
    if (widget.realtimeService != null) {
      unawaited(widget.realtimeService!.dispose());
    }
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
      realtime: widget.realtimeService,
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
