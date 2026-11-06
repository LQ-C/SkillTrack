import 'package:flutter/material.dart';

import '../../../core/utils/date_formatter.dart';
import '../../../app/app_theme.dart';
import '../../../app/widgets/app_content.dart';
import '../../../app/widgets/card_loading_view.dart';
import '../../../core/errors/app_exception.dart';
import '../../../app/router/app_router.dart';
import '../../../app/widgets/skilltrack_bottom_navigation.dart';
import '../models/app_notification.dart';
import '../viewmodels/notification_badge_controller.dart';
import '../viewmodels/notification_list_view_model.dart';
import '../widgets/notification_empty_state.dart';
import '../widgets/notification_filter_bar.dart';
import '../widgets/notification_tile.dart';

class NotificationScreen extends StatefulWidget {
  const NotificationScreen({
    super.key,
    required this.viewModel,
    required this.badgeController,
    this.showBottomNavigation = true,
    this.onOpenProjectDashboard,
  });
  final NotificationListViewModel viewModel;
  final NotificationBadgeController badgeController;
  final bool showBottomNavigation;
  final VoidCallback? onOpenProjectDashboard;

  @override
  State<NotificationScreen> createState() => _NotificationScreenState();
}

class _NotificationScreenState extends State<NotificationScreen> {
  String? _openingNotificationId;
  bool _isOpeningPreferences = false;
  final Set<String> _knownNotificationIds = {};
  final Set<String> _enteringNotificationIds = {};
  bool _hasNotificationBaseline = false;
  DateTime? _latestNotificationAt;

  // Observe the existing ViewModel only; no additional realtime subscription.
  void _trackArrivals() {
    final model = widget.viewModel;
    if (model.isLoading) return;
    final items = model.allNotifications;
    for (final item in items) {
      if (_hasNotificationBaseline &&
          !model.isRefreshing &&
          !_knownNotificationIds.contains(item.id) &&
          (_latestNotificationAt == null ||
              !item.createdAt.isBefore(_latestNotificationAt!))) {
        _enteringNotificationIds.add(item.id);
      }
    }
    _knownNotificationIds.addAll(items.map((item) => item.id));
    _enteringNotificationIds.retainAll(items.map((item) => item.id));
    for (final item in items) {
      if (_latestNotificationAt == null ||
          item.createdAt.isAfter(_latestNotificationAt!)) {
        _latestNotificationAt = item.createdAt;
      }
    }
    _hasNotificationBaseline = true;
  }

  @override
  void didUpdateWidget(covariant NotificationScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.viewModel != widget.viewModel) {
      oldWidget.viewModel.removeListener(_trackArrivals);
      _knownNotificationIds.clear();
      _enteringNotificationIds.clear();
      _hasNotificationBaseline = false;
      _latestNotificationAt = null;
      widget.viewModel.addListener(_trackArrivals);
      _trackArrivals();
    }
  }

  @override
  void dispose() {
    widget.viewModel.removeListener(_trackArrivals);
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    widget.viewModel.addListener(_trackArrivals);
    _trackArrivals();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.viewModel.initialize();
    });
  }

  Future<void> _open(AppNotification item) async {
    if (_openingNotificationId != null || _isOpeningPreferences) return;
    setState(() => _openingNotificationId = item.id);
    try {
      final destination = await widget.viewModel.openNotification(item);
      if (!mounted) return;
      _showFeedback();
      if (destination == null) return;
      if (destination.taskId == null) {
        final openProjects = widget.onOpenProjectDashboard;
        if (openProjects != null) {
          openProjects();
          return;
        } else {
          AppRouter.projectDashboard(context);
        }
      } else {
        await AppRouter.taskDetails(
          context,
          TaskDetailsRouteArgs(
            projectId: destination.projectId,
            boardId: destination.boardId,
            projectName: destination.projectName,
            taskId: destination.taskId!,
          ),
        );
      }
      if (mounted) await widget.viewModel.refresh();
    } finally {
      if (mounted) setState(() => _openingNotificationId = null);
    }
  }

  Future<void> _openPreferences() async {
    if (_isOpeningPreferences || _openingNotificationId != null) return;
    setState(() => _isOpeningPreferences = true);
    try {
      await AppRouter.notificationPreferences(context);
    } finally {
      if (mounted) setState(() => _isOpeningPreferences = false);
    }
  }

  void _showFeedback() {
    final message = widget.viewModel.feedbackMessage;
    if (message == null || !mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
    widget.viewModel.clearFeedbackMessage();
  }

  Future<void> _markAll() async {
    if (widget.viewModel.isMarkingAllRead) return;
    await widget.viewModel.markAllAsRead();
    _showFeedback();
  }

  String _group(DateTime date) {
    final local = DateFormatter.malaysiaTime(date);
    final today = DateFormatter.today();
    final day = DateUtils.dateOnly(local);
    if (day == today) return 'Today';
    if (day == DateTime(today.year, today.month, today.day - 1)) {
      return 'Yesterday';
    }
    return 'Earlier';
  }

  Widget _olderControl(NotificationListViewModel model) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Column(
      children: [
        if (model.loadMoreError != null)
          Text(model.loadMoreError!, textAlign: TextAlign.center),
        TextButton.icon(
          onPressed:
              model.isLoadingMore || model.isRefreshing || model.isLoading
              ? null
              : model.loadMore,
          icon: model.isLoadingMore
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.expand_more),
          label: const Text('Load older notifications'),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.viewModel,
    builder: (context, child) {
      final model = widget.viewModel;
      final theme = Theme.of(context);
      final items = model.visibleNotifications;
      return Scaffold(
        appBar: AppBar(
          title: const Text('Notifications'),
          actions: [
            IconButton(
              tooltip: 'Notification preferences',
              onPressed: _isOpeningPreferences || _openingNotificationId != null
                  ? null
                  : _openPreferences,
              icon: const Icon(Icons.settings_outlined),
            ),
            PopupMenuButton<String>(
              tooltip: 'Notification actions',
              onSelected: (_) => _markAll(),
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'read',
                  enabled:
                      model.unreadCount > 0 &&
                      !model.isMarkingAllRead &&
                      !model.isMarkingRead,
                  child: const Text('Mark all as read'),
                ),
              ],
            ),
          ],
        ),
        body: AppContent(
          child: Column(
            children: [
              NotificationFilterBar(
                selected: model.selectedFilter,
                unreadCount: model.unreadCount,
                onSelected: model.setFilter,
              ),
              Expanded(
                child: model.isLoading
                    ? const CardLoadingView(
                        label: 'Loading notifications',
                        showLeading: true,
                      )
                    : model.errorMessage != null
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.cloud_off_outlined,
                              size: 48,
                              color: theme.colorScheme.error,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              AppErrorMessages.loadNotificationsFailed,
                              style: theme.textTheme.titleMedium,
                            ),
                            Text(
                              'Please check your connection and try again.',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: 16),
                            FilledButton(
                              onPressed: model.retry,
                              child: const Text('Retry'),
                            ),
                          ],
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: model.refresh,
                        child: items.isEmpty
                            ? ListView(
                                children: [
                                  SizedBox(
                                    height:
                                        MediaQuery.sizeOf(context).height * .55,
                                    child: model.isEmpty
                                        ? const NotificationEmptyState(
                                            title: 'No notifications yet',
                                            message:
                                                'Task alerts, deadline reminders, and learning recommendations will appear here.',
                                          )
                                        : model.selectedFilter ==
                                              NotificationListFilter.unread
                                        ? const NotificationEmptyState(
                                            title: 'You’re all caught up',
                                            message:
                                                'You have no unread notifications.',
                                          )
                                        : const NotificationEmptyState(
                                            title: 'No matching notifications',
                                            message:
                                                'Try selecting another notification category.',
                                          ),
                                  ),
                                  if (model.hasMore) _olderControl(model),
                                ],
                              )
                            : ListView.builder(
                                padding: const EdgeInsets.fromLTRB(
                                  16,
                                  4,
                                  16,
                                  24,
                                ),
                                findChildIndexCallback: (key) {
                                  final index = items.indexWhere(
                                    (item) =>
                                        ValueKey(
                                          'notification-row-${item.id}',
                                        ) ==
                                        key,
                                  );
                                  return index < 0 ? null : index;
                                },
                                itemCount:
                                    items.length + (model.hasMore ? 1 : 0),
                                itemBuilder: (context, index) {
                                  if (index == items.length) {
                                    return _olderControl(model);
                                  }
                                  final item = items[index];
                                  final showHeading =
                                      index == 0 ||
                                      _group(items[index - 1].createdAt) !=
                                          _group(item.createdAt);
                                  final animateEntrance =
                                      _enteringNotificationIds.contains(
                                        item.id,
                                      );
                                  return _NotificationEntrance(
                                    key: ValueKey(
                                      'notification-row-${item.id}',
                                    ),
                                    animate: animateEntrance,
                                    onStarted: () => _enteringNotificationIds
                                        .remove(item.id),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        if (showHeading)
                                          Padding(
                                            padding: const EdgeInsets.fromLTRB(
                                              4,
                                              16,
                                              4,
                                              8,
                                            ),
                                            child: Text(
                                              _group(item.createdAt),
                                              style: theme.textTheme.titleSmall
                                                  ?.copyWith(
                                                    color: theme
                                                        .colorScheme
                                                        .onSurfaceVariant,
                                                  ),
                                            ),
                                          ),
                                        NotificationTile(
                                          key: Key('notification-${item.id}'),
                                          notification: item,
                                          onTap:
                                              _openingNotificationId != null ||
                                                  _isOpeningPreferences
                                              ? null
                                              : () => _open(item),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                      ),
              ),
            ],
          ),
        ),
        bottomNavigationBar: widget.showBottomNavigation
            ? SkillTrackBottomNavigation(
                selectedIndex: 3,
                badgeController: widget.badgeController,
                onProject: () => AppRouter.projectDashboard(context),
                onNotifications: () {},
                onUnavailable: (name) =>
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          '$name is not available in this prototype.',
                        ),
                      ),
                    ),
              )
            : null,
      );
    },
  );
}

/// Capture entrance state when mounted, so rebuilding or reordering a lazy
/// list cannot consume the effect before the row is actually displayed.
class _NotificationEntrance extends StatefulWidget {
  const _NotificationEntrance({
    super.key,
    required this.animate,
    required this.onStarted,
    required this.child,
  });
  final bool animate;
  final VoidCallback onStarted;
  final Widget child;

  @override
  State<_NotificationEntrance> createState() => _NotificationEntranceState();
}

class _NotificationEntranceState extends State<_NotificationEntrance> {
  late final double _begin;

  @override
  void initState() {
    super.initState();
    _begin = widget.animate ? 0 : 1;
    widget.onStarted();
  }

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: _begin, end: 1),
    duration: AppTheme.motionDuration(context, AppTheme.contentDuration),
    curve: AppTheme.transitionCurve,
    builder: (context, value, child) => Opacity(
      opacity: value,
      child: Transform.translate(
        offset: Offset(0, 6 * (1 - value)),
        child: child,
      ),
    ),
    child: widget.child,
  );
}
