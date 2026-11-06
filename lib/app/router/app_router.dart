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
import '../../features/ai_task_generation/repositories/ai_task_generation_repository.dart';
import '../../features/ai_task_generation/views/generated_task_preview_screen.dart';
import '../../features/ai_task_generation/view_models/generated_task_preview_state.dart';
import '../../features/ai_task_generation/view_models/append_task_generation_view_model.dart';
import '../../features/projects/views/create_project_screen.dart';
import '../../features/projects/views/project_dashboard_screen.dart';
import '../../features/projects/viewmodels/create_project_view_model.dart';
import '../../features/notifications/repositories/notification_repository.dart';
import '../../features/notifications/viewmodels/notification_badge_controller.dart';
import '../../features/notifications/services/notification_realtime_service.dart';
import '../../features/notifications/viewmodels/notification_preferences_view_model.dart';
import '../../features/notifications/views/notification_preferences_screen.dart';
import '../views/main_module_shell.dart';
import '../../features/notifications/viewmodels/push_notification_controller.dart';

class AppRoutes {
  static const projectDashboard = '/projects';
  static const createProject = '/projects/create';
  static const generatedTaskPreview = '/projects/create/generated-tasks';
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
    this.projectStatus = 'active',
  });
  final String projectId;
  final String boardId;
  final String projectName;
  final String projectStatus;
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

class GeneratedTaskPreviewRouteArgs {
  const GeneratedTaskPreviewRouteArgs(this.viewModel);
  final GeneratedTaskPreviewState viewModel;
  bool get isValid => viewModel.pendingGeneratedTasks.isNotEmpty;
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
  });
  final String projectId;
  final String boardId;
  final String projectName;
  final String taskId;
  bool get isValid =>
      projectId.trim().isNotEmpty &&
      boardId.trim().isNotEmpty &&
      taskId.trim().isNotEmpty;
}

class AppRouter {
  const AppRouter({
    required this.projectRepository,
    required this.kanbanRepository,
    this.taskGenerationRepository,
    this.notificationRepository,
    this.badgeController,
    this.realtime,
    this.pushPreferences,
  });
  final ProjectRepository projectRepository;
  final KanbanRepository kanbanRepository;
  final TaskGenerationRepository? taskGenerationRepository;
  final NotificationRepository? notificationRepository;
  final NotificationBadgeController? badgeController;
  final NotificationChangeSource? realtime;
  final PushPreferenceActions? pushPreferences;

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
                push: pushPreferences,
              );
      case AppRoutes.createProject:
        page = CreateProjectScreen(
          repository: projectRepository,
          generationRepository: taskGenerationRepository,
          taskRepository: kanbanRepository,
        );
      case AppRoutes.generatedTaskPreview:
        page = arguments is GeneratedTaskPreviewRouteArgs && arguments.isValid
            ? GeneratedTaskPreviewScreen(viewModel: arguments.viewModel)
            : const _RouteUnavailable();
      case AppRoutes.editProject:
        page = arguments is EditProjectRouteArgs && arguments.isValid
            ? _EditProjectRoute(
                repository: projectRepository,
                projectId: arguments.projectId,
              )
            : const _RouteUnavailable();
      case AppRoutes.kanbanBoard:
        page = arguments is BoardRouteArgs && arguments.isValid
            ? _BoardRoute(
                args: arguments,
                repository: kanbanRepository,
                projectRepository: projectRepository,
                generationRepository: taskGenerationRepository,
              )
            : const _RouteUnavailable(board: true);
      case AppRoutes.createTask:
        page = arguments is CreateTaskRouteArgs && arguments.isValid
            ? _TaskRoute(
                args: arguments,
                repository: kanbanRepository,
                projectRepository: projectRepository,
              )
            : const _RouteUnavailable();
      case AppRoutes.taskDetails:
        page = arguments is TaskDetailsRouteArgs && arguments.isValid
            ? _TaskDetailsRoute(
                args: arguments,
                repository: kanbanRepository,
                projectRepository: projectRepository,
              )
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

  static Future<ProjectWithProgress?> generatedTaskPreview(
    BuildContext context,
    CreateProjectViewModel viewModel,
  ) async =>
      (await Navigator.of(context).pushNamed<dynamic>(
            AppRoutes.generatedTaskPreview,
            arguments: GeneratedTaskPreviewRouteArgs(viewModel),
          ))
          as ProjectWithProgress?;

  static Future<bool?> additionalTaskPreview(
    BuildContext context,
    GeneratedTaskPreviewState viewModel,
  ) async =>
      (await Navigator.of(context).pushNamed<dynamic>(
            AppRoutes.generatedTaskPreview,
            arguments: GeneratedTaskPreviewRouteArgs(viewModel),
          ))
          as bool?;

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

  static void back<T extends Object?>(BuildContext context, [T? result]) {
    // A second callback from a closing route must not pop the page beneath it.
    if (ModalRoute.of(context)?.isCurrent == false) return;
    Navigator.of(context).pop<T>(result);
  }

  static bool openNotificationsFromPush(
    GlobalKey<NavigatorState> navigatorKey,
  ) {
    final navigator = navigatorKey.currentState;
    if (navigator == null) return false;
    navigator.pushNamedAndRemoveUntil<void>(
      AppRoutes.notifications,
      (_) => false,
    );
    return true;
  }

  static Future<void> notifications(BuildContext context) =>
      Navigator.of(context).pushNamed<void>(AppRoutes.notifications);

  static Future<void> notificationPreferences(BuildContext context) =>
      Navigator.of(context).pushNamed<void>(AppRoutes.notificationPreferences);

  static void projectDashboard(BuildContext context) => Navigator.of(
    context,
  ).popUntil((route) => route.settings.name == AppRoutes.projectDashboard);
}

class _NotificationPreferencesRoute extends StatefulWidget {
  const _NotificationPreferencesRoute({required this.repository, this.push});
  final PushPreferenceActions? push;
  final NotificationRepository repository;
  @override
  State<_NotificationPreferencesRoute> createState() =>
      _NotificationPreferencesRouteState();
}

class _NotificationPreferencesRouteState
    extends State<_NotificationPreferencesRoute> {
  late final NotificationPreferencesViewModel _model =
      NotificationPreferencesViewModel(widget.repository, push: widget.push);
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
  const _BoardRoute({
    required this.args,
    required this.repository,
    required this.projectRepository,
    required this.generationRepository,
  });
  final BoardRouteArgs args;
  final KanbanRepository repository;
  final ProjectRepository projectRepository;
  final TaskGenerationRepository? generationRepository;

  @override
  State<_BoardRoute> createState() => _BoardRouteState();
}

class _BoardRouteState extends State<_BoardRoute> {
  late final KanbanViewModel _model = KanbanViewModel(
    widget.repository,
    projectRepository: widget.projectRepository,
    projectId: widget.args.projectId,
  );
  late final AppendTaskGenerationViewModel? _append =
      widget.generationRepository == null
      ? null
      : AppendTaskGenerationViewModel(
          projectId: widget.args.projectId,
          boardId: widget.args.boardId,
          projectRepository: widget.projectRepository,
          taskRepository: widget.repository,
          generationRepository: widget.generationRepository!,
        );

  @override
  void dispose() {
    _model.dispose();
    _append?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => KanbanBoardScreen(
    viewModel: _model,
    appendViewModel: _append,
    projectId: widget.args.projectId,
    boardId: widget.args.boardId,
    projectName: widget.args.projectName,
    projectStatus: widget.args.projectStatus,
  );
}

class _TaskRoute extends StatefulWidget {
  const _TaskRoute({
    required this.args,
    required this.repository,
    required this.projectRepository,
  });
  final ProjectRepository projectRepository;
  final CreateTaskRouteArgs args;
  final KanbanRepository repository;

  @override
  State<_TaskRoute> createState() => _TaskRouteState();
}

class _TaskRouteState extends State<_TaskRoute> {
  late final KanbanViewModel _model = KanbanViewModel(
    widget.repository,
    projectRepository: widget.projectRepository,
    projectId: widget.args.projectId,
  );
  late final Future<void> _ready = _model.initialize(
    widget.args.boardId,
    widget.args.taskId,
  );

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
  const _TaskDetailsRoute({
    required this.args,
    required this.repository,
    required this.projectRepository,
  });
  final ProjectRepository projectRepository;
  final TaskDetailsRouteArgs args;
  final KanbanRepository repository;

  @override
  State<_TaskDetailsRoute> createState() => _TaskDetailsRouteState();
}

class _TaskDetailsRouteState extends State<_TaskDetailsRoute> {
  bool _isOpeningEdit = false;
  late final KanbanViewModel _model = KanbanViewModel(
    widget.repository,
    projectRepository: widget.projectRepository,
    projectId: widget.args.projectId,
  );
  late final Future<void> _ready = _model.initialize(
    widget.args.boardId,
    widget.args.taskId,
  );

  @override
  void dispose() {
    _model.dispose();
    super.dispose();
  }

  Future<void> _edit(KanbanTask task) async {
    if (_isOpeningEdit) return;
    setState(() => _isOpeningEdit = true);
    try {
      await AppRouter.createTask(
        context,
        CreateTaskRouteArgs(
          projectId: widget.args.projectId,
          boardId: widget.args.boardId,
          projectName: widget.args.projectName,
          taskId: task.id,
        ),
      );
      // Milestones can be saved even when the task itself was not changed.
      if (mounted) await _model.refresh();
    } finally {
      if (mounted) setState(() => _isOpeningEdit = false);
    }
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
          onEdit: _isOpeningEdit ? null : _edit,
          fullScreen: true,
        ),
      );
    },
  );
}
