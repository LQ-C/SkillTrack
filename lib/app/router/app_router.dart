import 'package:flutter/material.dart';

import '../../features/kanban/models/kanban_task.dart';
import '../../features/kanban/repositories/kanban_repository.dart';
import '../../features/kanban/viewmodels/archived_tasks_view_model.dart';
import '../../features/kanban/viewmodels/kanban_view_model.dart';
import '../../features/kanban/views/archived_tasks_screen.dart';
import '../../features/kanban/views/kanban_board_screen.dart';
import '../../features/kanban/widgets/task_details_sheet.dart';
import '../../features/kanban/widgets/task_form_sheet.dart';
import '../../features/projects/models/learning_project.dart';
import '../../features/projects/models/project_with_progress.dart';
import '../../features/projects/repositories/project_repository.dart';
import '../../features/projects/views/create_project_screen.dart';
import '../../features/projects/views/project_dashboard_screen.dart';
import '../../features/notifications/repositories/notification_repository.dart';
import '../../features/notifications/viewmodels/notification_badge_controller.dart';
import '../../features/notifications/services/notification_realtime_service.dart';
import '../../features/notifications/viewmodels/notification_preferences_view_model.dart';
import '../../features/notifications/views/notification_preferences_screen.dart';
import '../views/main_module_shell.dart';

class AppRoutes {
  static const projectDashboard = '/projects';
  static const createProject = '/projects/create';
  static const editProject = '/projects/edit';
  static const kanbanBoard = '/projects/board';
  static const createTask = '/projects/board/tasks/create';
  static const taskDetails = '/projects/board/tasks/details';
  static const archivedTasks = '/projects/board/tasks/archived';
  static const notifications = '/notifications';
  static const notificationPreferences = '/notifications/preferences';
}

class BoardRouteArgs {
  const BoardRouteArgs({
    required this.projectId,
    required this.boardId,
    required this.projectName,
  });
  final String projectId;
  final String boardId;
  final String projectName;
  bool get isValid =>
      projectId.trim().isNotEmpty &&
      boardId.trim().isNotEmpty &&
      projectName.trim().isNotEmpty;
}

class EditProjectRouteArgs {
  const EditProjectRouteArgs(this.projectId);
  final String projectId;
  bool get isValid => projectId.trim().isNotEmpty;
}

class CreateTaskRouteArgs extends BoardRouteArgs {
  const CreateTaskRouteArgs({
    required super.projectId,
    required super.boardId,
    required super.projectName,
    this.taskId,
  });
  final String? taskId;
}

class TaskDetailsRouteArgs {
  const TaskDetailsRouteArgs({
    required this.projectId,
    required this.boardId,
    required this.projectName,
    required this.taskId,
    this.showStalledWarning = false,
    this.openRecommendations = false,
    this.resourceTitles = const [],
    this.resourceCount = 0,
  });
  final String projectId;
  final String boardId;
  final String projectName;
  final String taskId;
  final bool showStalledWarning, openRecommendations;
  final List<String> resourceTitles;
  final int resourceCount;
  bool get isValid =>
      projectId.trim().isNotEmpty &&
      boardId.trim().isNotEmpty &&
      taskId.trim().isNotEmpty;
}

class AppRouter {
  const AppRouter({
    required this.projectRepository,
    required this.kanbanRepository,
    this.notificationRepository,
    this.badgeController,
    this.realtime,
  });
  final ProjectRepository projectRepository;
  final KanbanRepository kanbanRepository;
  final NotificationRepository? notificationRepository;
  final NotificationBadgeController? badgeController;
  final NotificationChangeSource? realtime;

  Route<dynamic> onGenerateRoute(RouteSettings settings) {
    final arguments = settings.arguments;
    Widget page;
    switch (settings.name) {
      case AppRoutes.projectDashboard:
      case AppRoutes.notifications:
        page = notificationRepository == null || badgeController == null
            ? settings.name == AppRoutes.projectDashboard
                  ? ProjectDashboardScreen(
                      projectRepository: projectRepository,
                      kanbanRepository: kanbanRepository,
                      badgeController: badgeController,
                    )
                  : const _RouteUnavailable()
            : MainModuleShell(
                initialPage: settings.name == AppRoutes.notifications
                    ? MainModulePage.notifications
                    : MainModulePage.projects,
                projectRepository: projectRepository,
                kanbanRepository: kanbanRepository,
                notificationRepository: notificationRepository!,
                badgeController: badgeController!,
                realtime: realtime,
              );
      case AppRoutes.notificationPreferences:
        page = notificationRepository == null
            ? const _RouteUnavailable()
            : _NotificationPreferencesRoute(
                repository: notificationRepository!,
              );
      case AppRoutes.createProject:
        page = CreateProjectScreen(repository: projectRepository);
      case AppRoutes.editProject:
        page = arguments is EditProjectRouteArgs && arguments.isValid
            ? _EditProjectRoute(
                repository: projectRepository,
                projectId: arguments.projectId,
              )
            : const _RouteUnavailable();
      case AppRoutes.kanbanBoard:
        page = arguments is BoardRouteArgs && arguments.isValid
            ? _BoardRoute(args: arguments, repository: kanbanRepository)
            : const _RouteUnavailable(board: true);
      case AppRoutes.createTask:
        page = arguments is CreateTaskRouteArgs && arguments.isValid
            ? _TaskRoute(args: arguments, repository: kanbanRepository)
            : const _RouteUnavailable();
      case AppRoutes.taskDetails:
        page = arguments is TaskDetailsRouteArgs && arguments.isValid
            ? _TaskDetailsRoute(args: arguments, repository: kanbanRepository)
            : const _RouteUnavailable();
      case AppRoutes.archivedTasks:
        page = arguments is BoardRouteArgs && arguments.isValid
            ? _ArchivedTasksRoute(args: arguments, repository: kanbanRepository)
            : const _RouteUnavailable(board: true);
      default:
        page = const _RouteUnavailable();
    }
    return MaterialPageRoute<dynamic>(settings: settings, builder: (_) => page);
  }

  static Future<ProjectWithProgress?> createProject(
    BuildContext context,
  ) async =>
      (await Navigator.of(context).pushNamed<dynamic>(AppRoutes.createProject))
          as ProjectWithProgress?;

  static Future<ProjectWithProgress?> editProject(
    BuildContext context,
    String projectId,
  ) async =>
      (await Navigator.of(context).pushNamed<dynamic>(
            AppRoutes.editProject,
            arguments: EditProjectRouteArgs(projectId),
          ))
          as ProjectWithProgress?;

  static Future<void> kanbanBoard(
    BuildContext context,
    BoardRouteArgs args,
  ) async {
    await Navigator.of(
      context,
    ).pushNamed<dynamic>(AppRoutes.kanbanBoard, arguments: args);
  }

  static Future<bool?> createTask(
    BuildContext context,
    CreateTaskRouteArgs args,
  ) async =>
      (await Navigator.of(
            context,
          ).pushNamed<dynamic>(AppRoutes.createTask, arguments: args))
          as bool?;

  static Future<void> taskDetails(
    BuildContext context,
    TaskDetailsRouteArgs args,
  ) async {
    await Navigator.of(
      context,
    ).pushNamed<dynamic>(AppRoutes.taskDetails, arguments: args);
  }

  static Future<void> archivedTasks(
    BuildContext context,
    BoardRouteArgs args,
  ) async {
    await Navigator.of(
      context,
    ).pushNamed<dynamic>(AppRoutes.archivedTasks, arguments: args);
  }

  static void back<T extends Object?>(BuildContext context, [T? result]) =>
      Navigator.of(context).pop<T>(result);

  static Future<void> notifications(BuildContext context) =>
      Navigator.of(context).pushNamed<void>(AppRoutes.notifications);

  static Future<void> notificationPreferences(BuildContext context) =>
      Navigator.of(context).pushNamed<void>(AppRoutes.notificationPreferences);

  static void projectDashboard(BuildContext context) => Navigator.of(
    context,
  ).popUntil((route) => route.settings.name == AppRoutes.projectDashboard);
}

class _NotificationPreferencesRoute extends StatefulWidget {
  const _NotificationPreferencesRoute({required this.repository});
  final NotificationRepository repository;
  @override
  State<_NotificationPreferencesRoute> createState() =>
      _NotificationPreferencesRouteState();
}

class _NotificationPreferencesRouteState
    extends State<_NotificationPreferencesRoute> {
  late final NotificationPreferencesViewModel _model =
      NotificationPreferencesViewModel(widget.repository);
  @override
  void dispose() {
    _model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      NotificationPreferencesScreen(viewModel: _model);
}

class _ArchivedTasksRoute extends StatefulWidget {
  const _ArchivedTasksRoute({required this.args, required this.repository});

  final BoardRouteArgs args;
  final KanbanRepository repository;

  @override
  State<_ArchivedTasksRoute> createState() => _ArchivedTasksRouteState();
}

class _ArchivedTasksRouteState extends State<_ArchivedTasksRoute> {
  late final ArchivedTasksViewModel _model = ArchivedTasksViewModel(
    widget.repository,
  );

  @override
  void dispose() {
    _model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ArchivedTasksScreen(
    viewModel: _model,
    boardId: widget.args.boardId,
    projectName: widget.args.projectName,
  );
}

class _RouteUnavailable extends StatelessWidget {
  const _RouteUnavailable({this.board = false});
  final bool board;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(board ? 'Board unavailable' : 'Page unavailable'),
    ),
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, size: 48),
          const SizedBox(height: 12),
          Text(board ? 'Board unavailable' : 'Page unavailable'),
          const SizedBox(height: 8),
          Text(
            board
                ? 'This project’s Kanban board could not be loaded.'
                : 'The requested project or task could not be opened.',
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: () => AppRouter.back(context),
            child: const Text('Return to Projects'),
          ),
        ],
      ),
    ),
  );
}

class _EditProjectRoute extends StatefulWidget {
  const _EditProjectRoute({required this.repository, required this.projectId});
  final ProjectRepository repository;
  final String projectId;

  @override
  State<_EditProjectRoute> createState() => _EditProjectRouteState();
}

class _EditProjectRouteState extends State<_EditProjectRoute> {
  late final Future<LearningProject?> _project = widget.repository.getProject(
    widget.projectId,
  );

  @override
  Widget build(BuildContext context) => FutureBuilder<LearningProject?>(
    future: _project,
    builder: (context, snapshot) {
      if (!snapshot.hasData &&
          !snapshot.hasError &&
          snapshot.connectionState != ConnectionState.done) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      final project = snapshot.data;
      return project == null
          ? const _RouteUnavailable()
          : CreateProjectScreen(
              repository: widget.repository,
              project: project,
            );
    },
  );
}

class _BoardRoute extends StatefulWidget {
  const _BoardRoute({required this.args, required this.repository});
  final BoardRouteArgs args;
  final KanbanRepository repository;

  @override
  State<_BoardRoute> createState() => _BoardRouteState();
}

class _BoardRouteState extends State<_BoardRoute> {
  late final KanbanViewModel _model = KanbanViewModel(widget.repository);

  @override
  void dispose() {
    _model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => KanbanBoardScreen(
    viewModel: _model,
    projectId: widget.args.projectId,
    boardId: widget.args.boardId,
    projectName: widget.args.projectName,
  );
}

class _TaskRoute extends StatefulWidget {
  const _TaskRoute({required this.args, required this.repository});
  final CreateTaskRouteArgs args;
  final KanbanRepository repository;

  @override
  State<_TaskRoute> createState() => _TaskRouteState();
}

class _TaskRouteState extends State<_TaskRoute> {
  late final KanbanViewModel _model = KanbanViewModel(widget.repository);
  late final Future<void> _ready = _model.initialize(widget.args.boardId);

  @override
  void dispose() {
    _model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<void>(
    future: _ready,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      if (_model.errorMessage != null ||
          _model.boardId != widget.args.boardId) {
        return const _RouteUnavailable();
      }
      final id = widget.args.taskId;
      final task = id == null
          ? null
          : _model.allTasks.where((item) => item.id == id).firstOrNull;
      if (id != null && task == null) return const _RouteUnavailable();
      return TaskFormSheet(viewModel: _model, task: task);
    },
  );
}

class _TaskDetailsRoute extends StatefulWidget {
  const _TaskDetailsRoute({required this.args, required this.repository});
  final TaskDetailsRouteArgs args;
  final KanbanRepository repository;

  @override
  State<_TaskDetailsRoute> createState() => _TaskDetailsRouteState();
}

class _TaskDetailsRouteState extends State<_TaskDetailsRoute> {
  late final KanbanViewModel _model = KanbanViewModel(widget.repository);
  late final Future<void> _ready = _model.initialize(widget.args.boardId);

  @override
  void dispose() {
    _model.dispose();
    super.dispose();
  }

  Future<void> _edit(KanbanTask task) async {
    final changed = await AppRouter.createTask(
      context,
      CreateTaskRouteArgs(
        projectId: widget.args.projectId,
        boardId: widget.args.boardId,
        projectName: widget.args.projectName,
        taskId: task.id,
      ),
    );
    if (changed == true) await _model.refresh();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<void>(
    future: _ready,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      final task = _model.allTasks
          .where((item) => item.id == widget.args.taskId)
          .firstOrNull;
      if (_model.errorMessage != null || task == null) {
        return const _RouteUnavailable();
      }
      return Scaffold(
        appBar: AppBar(title: const Text('Task Details')),
        body: TaskDetailsSheet(
          taskId: widget.args.taskId,
          viewModel: _model,
          onEdit: _edit,
          fullScreen: true,
          showStalledWarning: widget.args.showStalledWarning,
          showRecommendations: widget.args.openRecommendations,
          resourceTitles: widget.args.resourceTitles,
          resourceCount: widget.args.resourceCount,
        ),
      );
    },
  );
}
