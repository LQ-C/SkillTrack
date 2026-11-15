import 'package:skilltrack/app/widgets/skilltrack_logo.dart';
import '../widgets/project_carousel.dart';
import '../../../app/app_colors.dart';
import '../widgets/home_action_card.dart';
import 'package:flutter/material.dart';
import '../../../app/widgets/notification_bell.dart';
import '../../../app/router/app_router.dart';
import '../../../core/utils/date_formatter.dart';
import '../repositories/dashboard_repository.dart';
import '../viewmodels/dashboard_view_model.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.loadProfile,
    required this.onProfile,
    required this.onLibrary,
    this.onMentorship,
    this.onExplore,
    this.onProjects,
    this.repository,
    this.showBottomNavigation = true,
  });
  final Future<Map<String, dynamic>> Function() loadProfile;
  final Future<void> Function() onProfile;
  final Future<void> Function(String?) onLibrary;
  final Future<void> Function()? onMentorship, onExplore, onProjects;
  final DashboardRepository? repository;
  final bool showBottomNavigation;
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final vm = DashboardViewModel(
    widget.loadProfile,
    repository: widget.repository,
  );
  bool opening = false;
  @override
  void initState() {
    super.initState();
    vm.addListener(refresh);
    vm.load();
  }

  void refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    vm.dispose();
    super.dispose();
  }

  Future<void> open(Future<void> Function() action) async {
    if (opening) return;
    setState(() => opening = true);
    try {
      await action();
      if (mounted) await vm.load();
    } finally {
      if (mounted) setState(() => opening = false);
    }
  }

  Future<void> route(String name, {Object? arguments}) async {
    await Navigator.of(context).pushNamed(name, arguments: arguments);
  }

  Widget heading(String text) => Padding(
    padding: const EdgeInsets.only(top: 20, bottom: 8),
    child: Text(text, style: Theme.of(context).textTheme.titleMedium),
  );
  Widget notice(String section) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (vm.busy(section)) const LinearProgressIndicator(),
      if (vm.errors.contains(section))
        TextButton.icon(
          onPressed: vm.busy(section) ? null : () => vm.retry(section),
          icon: const Icon(Icons.refresh),
          label: Text('Could not load $section. Retry'),
        ),
    ],
  );
  Widget card(
    String title,
    String subtitle, {
    VoidCallback? onTap,
    IconData icon = Icons.arrow_forward,
  }) => Card(
    child: ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: onTap == null ? null : Icon(icon),
      onTap: opening ? null : onTap,
    ),
  );
  @override
  Widget build(BuildContext context) {
    final data = vm.projects;
    final session = vm.session;
    final canExplore =
        widget.onExplore != null && ['student', 'mentor'].contains(vm.role);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        centerTitle: false,
        titleSpacing: 8,
        title: const SkillTrackLogo(),

        actions: [
          const NotificationBell(),
          IconButton.filledTonal(
            tooltip: 'Your profile',
            onPressed: opening ? null : () => open(widget.onProfile),
            icon: Text(
              vm.name?.isNotEmpty == true
                  ? vm.name!.characters.first.toUpperCase()
                  : 'You',
            ),
          ),
          const SizedBox(width: 12),
        ],
      ),
      bottomNavigationBar: widget.showBottomNavigation
          ? NavigationBar(
              selectedIndex: 0,
              onDestinationSelected: (i) {
                if (i == 1 && canExplore) open(widget.onExplore!);
                if (i == (canExplore ? 2 : 1)) {
                  open(() => widget.onLibrary(null));
                }
                if (i == (canExplore ? 3 : 2)) open(widget.onProfile);
              },
              destinations: [
                const NavigationDestination(
                  icon: Icon(Icons.home_outlined),
                  label: 'Home',
                ),
                if (canExplore)
                  const NavigationDestination(
                    icon: Icon(Icons.explore_outlined),
                    label: 'Explore',
                  ),
                const NavigationDestination(
                  icon: Icon(Icons.auto_stories_outlined),
                  label: 'Library',
                ),
                const NavigationDestination(
                  icon: Icon(Icons.person_outline),
                  label: 'Profile',
                ),
              ],
            )
          : null,
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: vm.load,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 960),
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                children: [
                  Text(
                    vm.name?.isNotEmpty == true
                        ? 'Welcome back, ${vm.name}'
                        : 'Welcome back',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  notice('profile'),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF443775), Color(0xFF6558A6)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Row(
                          children: [
                            Icon(
                              Icons.eco_outlined,
                              color: Color(0xFFE4D8FF),
                              size: 24,
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'GROW A LITTLE EVERY DAY',
                                style: TextStyle(
                                  color: Color(0xFFE4D8FF),
                                  fontSize: 11,
                                  letterSpacing: 1.7,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'Small steps.\nReal skills.',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 28,
                            height: 1.1,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 10),
                        const Text(
                          'Find a mentor, book a session, and learn with materials they share with you.',
                          style: TextStyle(
                            color: Color(0xFFEAE4F5),
                            fontSize: 15,
                            height: 1.4,
                          ),
                        ),
                        const SizedBox(height: 12),
                        FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFFE4D8FF),
                            foregroundColor: forest,
                          ),
                          onPressed: opening
                              ? null
                              : () => open(() => widget.onLibrary(null)),
                          child: const Padding(
                            padding: EdgeInsets.symmetric(vertical: 4),
                            child: Row(
                              children: [
                                Expanded(child: Text('Explore the library')),
                                SizedBox(width: 8),
                                Icon(Icons.arrow_forward),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  heading('Project overview'),
                  notice('projects'),
                  if (data != null)
                    Card(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final metrics = [
                            (
                              data.active,
                              'Active projects',
                              Icons.folder_outlined,
                            ),
                            (
                              data.today,
                              'Tasks due today',
                              Icons.today_outlined,
                            ),
                            (
                              data.stalled,
                              'Stalled tasks',
                              Icons.pause_circle_outline,
                            ),
                          ];
                          final stacked =
                              constraints.maxWidth < 330 ||
                              MediaQuery.textScalerOf(context).scale(14) > 21;
                          final boxes = metrics
                              .map(
                                (m) => Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.surfaceContainerLow,
                                  ),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        m.$3,
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.primary,
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        '${m.$1}',
                                        style: Theme.of(
                                          context,
                                        ).textTheme.titleLarge,
                                      ),
                                      Text(m.$2, textAlign: TextAlign.center),
                                    ],
                                  ),
                                ),
                              )
                              .toList();
                          return Padding(
                            padding: const EdgeInsets.all(8),
                            child: stacked
                                ? Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      for (
                                        var i = 0;
                                        i < boxes.length;
                                        i++
                                      ) ...[
                                        if (i > 0) const SizedBox(height: 4),
                                        boxes[i],
                                      ],
                                    ],
                                  )
                                : IntrinsicHeight(
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        for (
                                          var i = 0;
                                          i < boxes.length;
                                          i++
                                        ) ...[
                                          if (i > 0) const SizedBox(width: 4),
                                          Expanded(child: boxes[i]),
                                        ],
                                      ],
                                    ),
                                  ),
                          );
                        },
                      ),
                    ),
                  Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 16,
                    children: [
                      heading('Your projects'),
                      TextButton(
                        onPressed: opening
                            ? null
                            : () => open(
                                widget.onProjects ??
                                    () => route(AppRoutes.projectDashboard),
                              ),
                        child: const Text('View all'),
                      ),
                    ],
                  ),
                  if (data != null && data.items.isEmpty)
                    card(
                      'Create your first project',
                      'Turn a learning goal into your next step.',
                      onTap: () => open(() => route(AppRoutes.createProject)),
                    ),
                  if (data != null && data.items.isNotEmpty)
                    ProjectCarousel(
                      projects: data.items.take(3).toList(),
                      onOpen: opening
                          ? null
                          : (item) => open(
                              () => AppRouter.kanbanBoard(
                                context,
                                BoardRouteArgs(
                                  projectId: item.project.id,
                                  boardId: item.boardId!,
                                  projectName: item.project.name,
                                  projectStatus: item.project.status,
                                ),
                              ),
                            ),
                    ),
                  const SizedBox(height: 20),
                  const Text(
                    'Make it your own',
                    style: TextStyle(
                      fontSize: 23,
                      fontWeight: FontWeight.w800,
                      color: forest,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'A good place to start, wherever you are in your journey.',
                    style: TextStyle(color: muted, height: 1.5),
                  ),
                  HomeActionCard(
                    icon: Icons.auto_stories_outlined,
                    title: 'Find your next lesson',
                    description:
                        'Your mentor’s shared videos and learning materials.',
                    action: 'Browse resources',
                    onTap: opening
                        ? null
                        : () => open(() => widget.onLibrary(null)),
                  ),
                  const SizedBox(height: 16),
                  if (widget.onMentorship != null) ...[
                    HomeActionCard(
                      icon: Icons.school_outlined,
                      title: 'Learn together',
                      description:
                          'Find a mentor, offer your expertise and manage your sessions.',
                      action: 'Open mentorship',
                      onTap: opening ? null : () => open(widget.onMentorship!),
                    ),
                  ],
                  if (session != null ||
                      vm.busy('session') ||
                      vm.errors.contains('session')) ...[
                    heading('Upcoming session'),
                    notice('session'),
                    if (session != null)
                      card(
                        session.mentorId == widget.repository?.userId
                            ? 'Learner: ${session.learnerName}'
                            : 'Mentor: ${session.mentorName}',
                        '${DateFormatter.calendarDate(session.start)} · ${TimeOfDay.fromDateTime(session.start).format(context)} · Confirmed',
                        onTap: widget.onMentorship == null
                            ? null
                            : () => open(widget.onMentorship!),
                      ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
