import 'package:flutter/material.dart';

import '../features/kanban/repositories/kanban_repository.dart';
import '../features/projects/repositories/project_repository.dart';
import 'app_theme.dart';
import 'router/app_router.dart';

class SkillTrackApp extends StatelessWidget {
  const SkillTrackApp({
    super.key,
    required this.projectRepository,
    required this.kanbanRepository,
  });
  final ProjectRepository projectRepository;
  final KanbanRepository kanbanRepository;
  @override
  Widget build(BuildContext context) {
    final router = AppRouter(
      projectRepository: projectRepository,
      kanbanRepository: kanbanRepository,
    );
    return MaterialApp(
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
