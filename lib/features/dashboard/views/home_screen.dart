import 'package:skilltrack/app/widgets/notification_bell.dart';
import 'package:skilltrack/features/dashboard/viewmodels/dashboard_view_model.dart';
import 'package:flutter/material.dart';
import 'package:skilltrack/app/app_colors.dart';
import 'package:skilltrack/features/dashboard/widgets/home_action_card.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.loadProfile,
    required this.onProfile,
    required this.onLibrary,
    this.onMentorship,
    this.onExplore,
    this.showBottomNavigation = true,
  });
  final bool showBottomNavigation;
  final Future<Map<String, dynamic>> Function() loadProfile;
  final Future<void> Function() onProfile;
  final Future<void> Function(String? category) onLibrary;
  final Future<void> Function()? onMentorship;
  final Future<void> Function()? onExplore;
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final viewModel = DashboardViewModel(widget.loadProfile);
  String? get name => viewModel.name;
  bool get loading => viewModel.loading;
  bool get failed => viewModel.failed;
  bool opening = false;
  bool get showExplore =>
      (viewModel.role == 'student' || viewModel.role == 'mentor') &&
      widget.onExplore != null;

  Future<void> openExplore() async {
    if (opening || !showExplore) return;
    setState(() => opening = true);
    try {
      await widget.onExplore!();
    } finally {
      if (mounted) setState(() => opening = false);
    }
  }

  void refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    viewModel.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    viewModel.addListener(refresh);
    load();
  }

  Future<void> load() => viewModel.load();

  Future<void> openProfile() async {
    if (opening) return;
    setState(() => opening = true);
    try {
      await widget.onProfile();
      if (mounted) await load();
    } finally {
      if (mounted) setState(() => opening = false);
    }
  }

  Future<void> openLibrary() async {
    if (opening) return;
    setState(() => opening = true);
    try {
      await widget.onLibrary(null);
    } finally {
      if (mounted) setState(() => opening = false);
    }
  }

  Future<void> openMentorship() async {
    if (opening || widget.onMentorship == null) return;
    setState(() => opening = true);
    try {
      await widget.onMentorship!();
      if (mounted) await load();
    } finally {
      if (mounted) setState(() => opening = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      backgroundColor: Colors.transparent,
      title: const Row(
        children: [
          Icon(Icons.spa_outlined, color: forest),
          SizedBox(width: 9),
          Flexible(
            child: Text(
              'SkillTrack',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontWeight: FontWeight.w800, color: forest),
            ),
          ),
        ],
      ),
      actions: [
        const NotificationBell(),
        Padding(
          padding: const EdgeInsets.only(right: 14),
          child: IconButton.filledTonal(
            tooltip: 'Your profile',
            onPressed: opening ? null : openProfile,
            icon: Text(
              name?.isNotEmpty == true
                  ? name!.characters.first.toUpperCase()
                  : 'You',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ),
        ),
      ],
    ),
    bottomNavigationBar: widget.showBottomNavigation
        ? NavigationBar(
            selectedIndex: 0,
            onDestinationSelected: opening
                ? null
                : (index) {
                    if (showExplore && index == 1) {
                      openExplore();
                      return;
                    }
                    if (index == (showExplore ? 2 : 1)) openLibrary();
                    if (index == (showExplore ? 3 : 2)) openProfile();
                  },
            destinations: [
              const NavigationDestination(
                icon: Icon(Icons.home_outlined),
                selectedIcon: Icon(Icons.home),
                label: 'Home',
              ),
              if (showExplore)
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
        onRefresh: load,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(22, 16, 22, 32),
              children: [
                Text(
                  loading
                      ? 'Welcome to your learning space'
                      : name == null || name!.isEmpty
                      ? 'Welcome back'
                      : 'Welcome back, $name',
                  style: const TextStyle(fontSize: 16, color: muted),
                ),
                const SizedBox(height: 18),
                Container(
                  padding: const EdgeInsets.all(26),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF443775), Color(0xFF6558A6)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(26),
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
                      const SizedBox(height: 22),
                      const Text(
                        'Small steps.\nReal skills.',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 40,
                          height: 1.1,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'Find a mentor, book a session, and learn with materials they share with you.',
                        style: TextStyle(
                          color: Color(0xFFEAE4F5),
                          fontSize: 15,
                          height: 1.6,
                        ),
                      ),
                      const SizedBox(height: 24),
                      FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFFE4D8FF),
                          foregroundColor: forest,
                        ),
                        onPressed: opening ? null : () => openLibrary(),
                        child: const Padding(
                          padding: EdgeInsets.symmetric(vertical: 10),
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
                const SizedBox(height: 28),
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
                  onTap: opening ? null : () => openLibrary(),
                ),
                const SizedBox(height: 28),
                if (widget.onMentorship != null) ...[
                  HomeActionCard(
                    icon: Icons.school_outlined,
                    title: 'Learn together',
                    description:
                        'Find a mentor, offer your expertise and manage your sessions.',
                    action: 'Open mentorship',
                    onTap: opening ? null : openMentorship,
                  ),
                ],
                if (failed)
                  Padding(
                    padding: const EdgeInsets.only(top: 18),
                    child: Column(
                      children: [
                        const Text(
                          'Your profile details could not be loaded. You can still explore the library.',
                          style: TextStyle(color: muted),
                        ),
                        TextButton(
                          onPressed: load,
                          child: const Text('Retry profile'),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
