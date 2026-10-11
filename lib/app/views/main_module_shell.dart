import 'package:flutter/material.dart';

import '../../features/kanban/repositories/kanban_repository.dart';
import '../../features/kanban/widgets/skilltrack_bottom_navigation.dart';
import '../../features/notifications/repositories/notification_repository.dart';
import '../../features/notifications/services/notification_realtime_service.dart';
import '../../features/notifications/viewmodels/notification_badge_controller.dart';
import '../../features/notifications/viewmodels/notification_list_view_model.dart';
import '../../features/notifications/views/notification_screen.dart';
import '../../features/projects/repositories/project_repository.dart';
import '../../features/projects/views/project_dashboard_screen.dart';

enum MainModulePage { projects, notifications }

class MainModuleShell extends StatefulWidget {
  const MainModuleShell({
    super.key,
    required this.projectRepository,
    required this.kanbanRepository,
    required this.notificationRepository,
    required this.badgeController,
    this.realtime,
    this.initialPage = MainModulePage.projects,
  });

  final ProjectRepository projectRepository;
  final KanbanRepository kanbanRepository;
  final NotificationRepository notificationRepository;
  final NotificationBadgeController badgeController;
  final NotificationChangeSource? realtime;
  final MainModulePage initialPage;

  @override
  State<MainModuleShell> createState() => _MainModuleShellState();
}

class _MainModuleShellState extends State<MainModuleShell> {
  late final PageController _pageController;
  late final NotificationListViewModel _notifications;
  late final List<Widget> _pages;
  late MainModulePage _selectedPage;

  @override
  void initState() {
    super.initState();
    _selectedPage = widget.initialPage;
    _pageController = PageController(initialPage: _selectedPage.index);
    _notifications = NotificationListViewModel(
      widget.notificationRepository,
      widget.projectRepository,
      widget.kanbanRepository,
      widget.badgeController,
      widget.realtime,
    );
    _pages = [
      _KeepAliveModule(
        child: ProjectDashboardScreen(
          projectRepository: widget.projectRepository,
          kanbanRepository: widget.kanbanRepository,
          badgeController: widget.badgeController,
          showBottomNavigation: false,
        ),
      ),
      _KeepAliveModule(
        child: NotificationScreen(
          viewModel: _notifications,
          badgeController: widget.badgeController,
          showBottomNavigation: false,
          onOpenProjectDashboard: () => _selectPage(MainModulePage.projects),
        ),
      ),
    ];
  }

  void _selectPage(MainModulePage page) {
    if (_selectedPage == page || !_pageController.hasClients) return;
    _pageController.animateToPage(
      page.index,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void dispose() {
    _pageController.dispose();
    _notifications.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope<Object?>(
    canPop: _selectedPage == MainModulePage.projects,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _selectPage(MainModulePage.projects);
    },
    child: Scaffold(
      body: PageView(
        controller: _pageController,
        physics: const PageScrollPhysics(),
        onPageChanged: (index) => setState(() {
          _selectedPage = MainModulePage.values[index];
        }),
        children: _pages,
      ),
      bottomNavigationBar: SkillTrackBottomNavigation(
        selectedIndex: _selectedPage.index + 2,
        badgeController: widget.badgeController,
        onProject: () => _selectPage(MainModulePage.projects),
        onNotifications: () => _selectPage(MainModulePage.notifications),
        onUnavailable: (name) => ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$name is not available in this prototype.')),
        ),
      ),
    ),
  );
}

class _KeepAliveModule extends StatefulWidget {
  const _KeepAliveModule({required this.child});

  final Widget child;

  @override
  State<_KeepAliveModule> createState() => _KeepAliveModuleState();
}

class _KeepAliveModuleState extends State<_KeepAliveModule>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
