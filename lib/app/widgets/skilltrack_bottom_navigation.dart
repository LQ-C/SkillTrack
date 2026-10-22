import 'package:flutter/material.dart';

import '../app_theme.dart';

import '../../features/notifications/viewmodels/notification_badge_controller.dart';

class SkillTrackBottomNavigation extends StatelessWidget {
  const SkillTrackBottomNavigation({
    super.key,
    required this.onUnavailable,
    required this.onNotifications,
    required this.onProject,
    required this.badgeController,
    this.selectedIndex = 2,
  });
  final ValueChanged<String> onUnavailable;
  final VoidCallback onNotifications, onProject;
  final NotificationBadgeController badgeController;
  final int selectedIndex;

  Widget _notificationIcon(IconData icon) {
    final count = badgeController.unreadCount;
    return Semantics(
      label: count == 0
          ? 'No unread notifications'
          : '$count unread notifications',
      liveRegion: true,
      child: count == 0
          ? Icon(icon)
          : Badge(
              label: Text(count > 99 ? '99+' : '$count'),
              child: Icon(icon),
            ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: badgeController,
    builder: (context, child) => DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
        ),
      ),
      child: NavigationBar(
        animationDuration: AppTheme.motionDuration(context),
        selectedIndex: selectedIndex,
        height: 72,
        onDestinationSelected: (index) {
          if (index == 2) {
            if (selectedIndex != 2) onProject();
            return;
          }
          if (index == 3) {
            if (selectedIndex != 3) onNotifications();
            return;
          }
          onUnavailable(
            [
              'Home',
              'Marketplace',
              'Project',
              'Notifications',
              'Profile',
            ][index],
          );
        },
        destinations: [
          const NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'Home',
          ),
          const NavigationDestination(
            icon: Icon(Icons.storefront_outlined),
            label: 'Marketplace',
          ),
          const NavigationDestination(
            icon: Icon(Icons.folder_outlined),
            selectedIcon: Icon(Icons.folder),
            label: 'Project',
          ),
          NavigationDestination(
            icon: _notificationIcon(Icons.notifications_outlined),
            selectedIcon: _notificationIcon(Icons.notifications),
            label: 'Notifications',
          ),
          const NavigationDestination(
            icon: Icon(Icons.person_outline),
            label: 'Profile',
          ),
        ],
      ),
    ),
  );
}
