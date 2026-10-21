import 'package:flutter/material.dart';

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
  @override
  void initState() {
    super.initState();
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
            showStalledWarning: destination.showStalledWarning,
            openRecommendations: destination.openRecommendations,
            resourceTitles: destination.resourceTitles,
            resourceCount: destination.resourceCount,
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
    final local = date.toLocal();
    final today = DateUtils.dateOnly(DateTime.now());
    final day = DateUtils.dateOnly(local);
    if (day == today) return 'Today';
    if (day == today.subtract(const Duration(days: 1))) return 'Yesterday';
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
        body: Column(
          children: [
            NotificationFilterBar(
              selected: model.selectedFilter,
              unreadCount: model.unreadCount,
              onSelected: model.setFilter,
            ),
            Expanded(
              child: model.isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : model.errorMessage != null
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.cloud_off_outlined, size: 48),
                          const SizedBox(height: 12),
                          const Text(AppErrorMessages.loadNotificationsFailed),
                          const Text(
                            'Please check your connection and try again.',
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
                              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                              itemCount: items.length + (model.hasMore ? 1 : 0),
                              itemBuilder: (context, index) {
                                if (index == items.length) {
                                  return _olderControl(model);
                                }
                                final item = items[index];
                                final showHeading =
                                    index == 0 ||
                                    _group(items[index - 1].createdAt) !=
                                        _group(item.createdAt);
                                return Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
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
                                          style: Theme.of(
                                            context,
                                          ).textTheme.titleSmall,
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
                                );
                              },
                            ),
                    ),
            ),
          ],
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
