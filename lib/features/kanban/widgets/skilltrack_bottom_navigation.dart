import 'package:flutter/material.dart';

class SkillTrackBottomNavigation extends StatelessWidget {
  const SkillTrackBottomNavigation({super.key, required this.onUnavailable});
  final ValueChanged<String> onUnavailable;
  @override
  Widget build(BuildContext context) => NavigationBar(
    selectedIndex: 2,
    height: 72,
    onDestinationSelected: (index) {
      if (index != 2) {
        onUnavailable(
          ['Home', 'Marketplace', 'Project', 'Notifications', 'Profile'][index],
        );
      }
    },
    destinations: const [
      NavigationDestination(
        icon: Icon(Icons.home_outlined),
        selectedIcon: Icon(Icons.home),
        label: 'Home',
      ),
      NavigationDestination(
        icon: Icon(Icons.storefront_outlined),
        label: 'Marketplace',
      ),
      NavigationDestination(
        icon: Icon(Icons.folder_outlined),
        selectedIcon: Icon(Icons.folder),
        label: 'Project',
      ),
      NavigationDestination(
        icon: Badge(child: Icon(Icons.notifications_outlined)),
        label: 'Notifications',
      ),
      NavigationDestination(icon: Icon(Icons.person_outline), label: 'Profile'),
    ],
  );
}
