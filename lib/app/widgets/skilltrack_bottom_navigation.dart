import 'package:flutter/material.dart';
import '../../features/notifications/viewmodels/notification_badge_controller.dart';

class SkillTrackBottomNavigation extends StatelessWidget {
  const SkillTrackBottomNavigation({
    super.key,
    this.onUnavailable,
    this.onNotifications,
    this.onProject,
    this.badgeController,
    this.selectedIndex = 3,
    this.onDestinationSelected,
  });
  final ValueChanged<String>? onUnavailable;
  final VoidCallback? onNotifications, onProject;
  final NotificationBadgeController? badgeController;
  final int selectedIndex;
  final ValueChanged<int>? onDestinationSelected;
  @override
  Widget build(BuildContext context) => NavigationBar(
    selectedIndex: selectedIndex,
    onDestinationSelected: (index) {
      if (index == selectedIndex) return;
      if (onDestinationSelected != null) {
        onDestinationSelected!(index);
      } else if (index == 3) {
        onProject?.call();
      }
    },
    destinations: const [
      NavigationDestination(icon: Icon(Icons.home_outlined), label: 'Home'),
      NavigationDestination(
        icon: Icon(Icons.explore_outlined),
        label: 'Explore',
      ),
      NavigationDestination(
        icon: Icon(Icons.local_library_outlined),
        label: 'Library',
      ),
      NavigationDestination(
        icon: Icon(Icons.folder_outlined),
        label: 'Project',
      ),
      NavigationDestination(icon: Icon(Icons.person_outline), label: 'Profile'),
    ],
  );
}
