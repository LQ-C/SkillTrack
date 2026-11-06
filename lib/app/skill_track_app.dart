import 'dart:async';

import 'package:flutter/material.dart';

import '../features/kanban/repositories/kanban_repository.dart';
import '../features/projects/repositories/project_repository.dart';
import '../features/ai_task_generation/repositories/ai_task_generation_repository.dart';
import '../features/notifications/repositories/notification_repository.dart';
import '../features/notifications/viewmodels/notification_badge_controller.dart';
import '../features/notifications/services/notification_realtime_service.dart';
import '../features/notifications/viewmodels/push_notification_controller.dart';
import '../features/notifications/services/push_notification_service.dart';
import 'app_theme.dart';
import 'router/app_router.dart';

class SkillTrackApp extends StatefulWidget {
  const SkillTrackApp({
    super.key,
    required this.projectRepository,
    required this.kanbanRepository,
    this.taskGenerationRepository,
    this.notificationRepository,
    this.realtimeService,
    this.authEvents,
    this.pushController,
  });
  final ProjectRepository projectRepository;
  final KanbanRepository kanbanRepository;
  final TaskGenerationRepository? taskGenerationRepository;
  final NotificationRepository? notificationRepository;
  final NotificationRealtimeService? realtimeService;
  final Stream<Object?>? authEvents;
  final PushNotificationController? pushController;
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
  StreamSubscription<PushNotificationTap>? _pushSubscription;
  final _navigatorKey = GlobalKey<NavigatorState>();
  bool _pendingPushNavigation = false;
  String? _attachmentCleanupUser;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pushSubscription = widget.pushController?.taps.listen((_) {
      _pendingPushNavigation = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            _pendingPushNavigation &&
            widget.notificationRepository?.currentUserId != null &&
            AppRouter.openNotificationsFromPush(_navigatorKey)) {
          _pendingPushNavigation = false;
        }
      });
      WidgetsBinding.instance.ensureVisualUpdate();
    });
    _authSubscription = widget.authEvents?.listen((_) {
      unawaited(_syncSession());
    });
    unawaited(_syncSession());
  }

  Future<void> _syncSession({bool resumed = false}) async {
    final cleanupUser = widget.kanbanRepository.currentUserId;
    if (cleanupUser != null &&
        (resumed || cleanupUser != _attachmentCleanupUser)) {
      unawaited(widget.kanbanRepository.retryAttachmentCleanup());
    }
    _attachmentCleanupUser = cleanupUser;
    unawaited(
      widget.pushController?.syncSession(resumed: resumed) ?? Future.value(),
    );
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
    _pushSubscription?.cancel();
    if (widget.pushController != null) {
      unawaited(widget.pushController!.dispose());
    }
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
      taskGenerationRepository: widget.taskGenerationRepository,
      notificationRepository: widget.notificationRepository,
      badgeController: _badge,
      realtime: widget.realtimeService,
      pushPreferences: widget.pushController,
    );
    return MaterialApp(
      navigatorKey: _navigatorKey,
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
