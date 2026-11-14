import '../widgets/skilltrack_bottom_navigation.dart';
import 'package:flutter/material.dart';
import '../marketplace_dependencies.dart';
import '../router/app_router.dart';
import '../widgets/notification_bell.dart';
import '../../features/dashboard/views/home_screen.dart';
import '../../features/educational_content/views/content_screen.dart';
import '../../features/profile/views/profile_screen.dart';
import '../../features/tutor_management/views/explore_mentors_screen.dart';
import '../../features/kanban/repositories/kanban_repository.dart';
import '../../features/notifications/repositories/notification_repository.dart';
import '../../features/notifications/services/notification_realtime_service.dart';
import '../../features/notifications/viewmodels/notification_badge_controller.dart';
import '../../features/projects/repositories/project_repository.dart';
import '../../features/projects/views/project_dashboard_screen.dart';

enum MainModulePage { home, explore, library, projects, profile, notifications }

class MainModuleShell extends StatefulWidget {
  const MainModuleShell({
    super.key,
    required this.projectRepository,
    required this.kanbanRepository,
    required this.notificationRepository,
    required this.badgeController,
    this.marketplace,
    this.realtime,
    this.initialPage = MainModulePage.home,
    this.initialNotificationId,
  });
  final ProjectRepository projectRepository;
  final KanbanRepository kanbanRepository;
  final NotificationRepository notificationRepository;
  final NotificationBadgeController badgeController;
  final MarketplaceDependencies? marketplace;
  final NotificationChangeSource? realtime;
  final MainModulePage initialPage;
  final String? initialNotificationId;
  @override
  State<MainModuleShell> createState() => _MainModuleShellState();
}

class _MainModuleShellState extends State<MainModuleShell> {
  late int selected = widget.marketplace == null
      ? 3
      : widget.initialPage.index.clamp(0, 4);
  final visited = <int>{};
  final pages = <int, Widget>{};
  void select(int index) {
    if (selected == index) return;
    setState(() => selected = index);
  }

  Widget page(int index) {
    final m = widget.marketplace;
    if (index == 3) {
      return ProjectDashboardScreen(
        projectRepository: widget.projectRepository,
        kanbanRepository: widget.kanbanRepository,
        badgeController: widget.badgeController,
        showBottomNavigation: false,
      );
    }
    if (m == null) {
      return const Center(child: Text('Account service unavailable.'));
    }
    return switch (index) {
      0 => HomeScreen(
        showBottomNavigation: false,
        repository: m.dashboard,
        onProjects: () async => select(3),
        loadProfile: m.accounts.loadProfile,
        onProfile: () async => select(4),
        onExplore: () async => select(1),
        onLibrary: (_) async => select(2),
        onMentorship: () => AppRouter.openMentorship(context, m.accounts),
      ),
      1 => ExploreMentorsScreen(repository: m.tutors),
      2 => ContentScreen(repository: m.content),
      _ => ProfileScreen(service: m.accounts),
    };
  }

  @override
  Widget build(BuildContext context) {
    visited.add(selected);
    return NotificationBellScope(
      controller: widget.badgeController,
      child: PopScope<Object?>(
        canPop: selected == 0,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) select(0);
        },
        child: Scaffold(
          body: IndexedStack(
            index: selected,
            children: List.generate(
              5,
              (i) => visited.contains(i)
                  ? pages.putIfAbsent(i, () => page(i))
                  : const SizedBox.shrink(),
            ),
          ),
          bottomNavigationBar: SkillTrackBottomNavigation(
            selectedIndex: selected,
            onDestinationSelected: select,
          ),
        ),
      ),
    );
  }
}
