import 'package:flutter/material.dart';

import '../../../app/router/app_router.dart';
import '../../kanban/repositories/kanban_repository.dart';
import '../../kanban/widgets/skilltrack_bottom_navigation.dart';
import '../models/project_with_progress.dart';
import '../repositories/project_repository.dart';
import '../viewmodels/project_dashboard_view_model.dart';
import '../../notifications/viewmodels/notification_badge_controller.dart';

class ProjectDashboardScreen extends StatefulWidget {
  const ProjectDashboardScreen({
    super.key,
    required this.projectRepository,
    required this.kanbanRepository,
    this.badgeController,
    this.showBottomNavigation = true,
  });
  final ProjectRepository projectRepository;
  final KanbanRepository kanbanRepository;
  final NotificationBadgeController? badgeController;
  final bool showBottomNavigation;

  @override
  State<ProjectDashboardScreen> createState() => _ProjectDashboardScreenState();
}

class _ProjectDashboardScreenState extends State<ProjectDashboardScreen> {
  late final ProjectDashboardViewModel _model;
  NotificationBadgeController? _fallbackBadge;
  final _search = TextEditingController();
  bool _showSearch = false;

  @override
  void initState() {
    super.initState();
    _model = ProjectDashboardViewModel(widget.projectRepository);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _model.isSignedIn) _model.load();
    });
  }

  @override
  void dispose() {
    _model.dispose();
    _fallbackBadge?.dispose();
    _search.dispose();
    super.dispose();
  }

  void _snack(String message) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(message)));

  Future<void> _openProject(ProjectWithProgress item) async {
    String? boardId;
    try {
      boardId = await _model.boardFor(item.project.id);
    } catch (_) {
      boardId = null;
    }
    if (!mounted) return;
    await AppRouter.kanbanBoard(
      context,
      BoardRouteArgs(
        projectId: item.project.id,
        boardId: boardId ?? '',
        projectName: item.project.name,
      ),
    );
    if (mounted) await _model.load();
  }

  Future<void> _openForm([ProjectWithProgress? item]) async {
    final future = item == null
        ? AppRouter.createProject(context)
        : AppRouter.editProject(context, item.project.id);
    final created = await future;
    if (created == null || !mounted) return;
    await _model.load();
    if (!mounted) return;
    _snack(item == null ? 'Project created successfully' : 'Project updated');
    if (item == null) await _openProject(created);
  }

  Future<void> _delete(ProjectWithProgress item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete project?'),
        content: const Text(
          'This will permanently delete the project, its Kanban board, tasks, checklists, tags assigned to tasks, attachments metadata, and task activity.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Delete Project'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final ok = await _model.delete(item.project.id);
    if (mounted) _snack(ok ? 'Project deleted' : 'Unable to delete project');
  }

  Future<void> _action(ProjectWithProgress item, String action) async {
    switch (action) {
      case 'open':
        await _openProject(item);
      case 'edit':
        await _openForm(item);
      case 'complete':
        final ok = await _model.markCompleted(item);
        if (mounted) {
          _snack(ok ? 'Project completed' : 'Unable to update project');
        }
      case 'archive':
        final ok = await _model.archive(item.project.id);
        if (mounted) {
          _snack(ok ? 'Project archived' : 'Unable to archive project');
        }
      case 'delete':
        await _delete(item);
    }
  }

  String _dates(ProjectWithProgress item) {
    String date(DateTime value) =>
        '${value.day.toString().padLeft(2, '0')}/${value.month.toString().padLeft(2, '0')}/${value.year}';
    final start = item.project.startDate;
    final end = item.project.endDate;
    if (start == null && end == null) return '';
    if (start == null) return 'Until ${date(end!)}';
    if (end == null) return 'From ${date(start)}';
    return '${date(start)} – ${date(end)}';
  }

  Widget _projectCard(ProjectWithProgress item) {
    final project = item.project;
    final theme = Theme.of(context);
    final dates = _dates(item);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        key: Key('project-${project.id}'),
        borderRadius: BorderRadius.circular(16),
        onTap: () => _openProject(item),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      project.name,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  PopupMenuButton<String>(
                    tooltip: 'Project actions',
                    onSelected: (action) => _action(item, action),
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                        value: 'open',
                        child: Text('Open Project'),
                      ),
                      const PopupMenuItem(
                        value: 'edit',
                        child: Text('Edit Project'),
                      ),
                      if (project.status != 'completed')
                        const PopupMenuItem(
                          value: 'complete',
                          child: Text('Mark Completed'),
                        ),
                      if (project.status != 'archived')
                        const PopupMenuItem(
                          value: 'archive',
                          child: Text('Archive Project'),
                        ),
                      const PopupMenuItem(
                        value: 'delete',
                        child: Text('Delete Project'),
                      ),
                    ],
                  ),
                ],
              ),
              Text(
                project.status[0].toUpperCase() + project.status.substring(1),
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
              if (project.description?.isNotEmpty == true) ...[
                const SizedBox(height: 8),
                Text(
                  project.description!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              if (dates.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(dates, style: theme.textTheme.bodySmall),
              ],
              const SizedBox(height: 14),
              LinearProgressIndicator(value: item.progress, minHeight: 8),
              const SizedBox(height: 8),
              Text(
                '${item.completedTaskCount} of ${item.totalTaskCount} tasks completed',
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _summary() => Row(
    children: [
      for (final entry in [
        ('Total', _model.totalCount),
        ('Active', _model.activeCount),
        ('Completed', _model.completedCount),
      ])
        Expanded(
          child: Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
              child: Column(
                children: [
                  Text(
                    '${entry.$2}',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  Text(entry.$1),
                ],
              ),
            ),
          ),
        ),
    ],
  );

  Widget _state(
    String title,
    String message, {
    String? action,
    VoidCallback? onTap,
  }) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.folder_outlined,
            size: 54,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 12),
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(message, textAlign: TextAlign.center),
          if (action != null) ...[
            const SizedBox(height: 18),
            FilledButton(onPressed: onTap, child: Text(action)),
          ],
        ],
      ),
    ),
  );

  Future<void> _signIn() async {
    await showDialog<void>(
      context: context,
      builder: (_) => _SignInDialog(viewModel: _model),
    );
    await widget.badgeController?.refresh();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _model,
    builder: (context, child) {
      final visible = _model.visibleProjects;
      return Scaffold(
        appBar: AppBar(
          title: _showSearch
              ? TextField(
                  controller: _search,
                  autofocus: true,
                  onChanged: _model.search,
                  decoration: const InputDecoration(
                    hintText: 'Search projects',
                  ),
                )
              : const Text('My Projects'),
          actions: [
            IconButton(
              tooltip: _showSearch ? 'Close search' : 'Search projects',
              onPressed: () => setState(() {
                _showSearch = !_showSearch;
                if (!_showSearch) {
                  _search.clear();
                  _model.search('');
                }
              }),
              icon: Icon(_showSearch ? Icons.close : Icons.search),
            ),
          ],
        ),
        body: !_model.isSignedIn
            ? _state(
                'Sign in to view projects',
                'Your projects are linked to your account.',
                action: 'Sign in',
                onTap: _signIn,
              )
            : _model.isLoading
            ? const Center(child: CircularProgressIndicator())
            : _model.errorMessage != null
            ? _state(
                'Unable to load projects',
                'Please check your connection and try again.',
                action: 'Retry',
                onTap: _model.load,
              )
            : _model.projects.isEmpty
            ? _state(
                'No projects yet',
                'Create a project to organize your learning tasks.',
                action: 'Create Project',
                onTap: _openForm,
              )
            : Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                    child: _summary(),
                  ),
                  SizedBox(
                    height: 54,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      children: [
                        for (final filter in const [
                          'current',
                          'active',
                          'completed',
                          'archived',
                          'all',
                        ])
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ChoiceChip(
                              label: Text(
                                filter[0].toUpperCase() + filter.substring(1),
                              ),
                              selected: _model.statusFilter == filter,
                              onSelected: (_) => _model.filter(filter),
                            ),
                          ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: visible.isEmpty
                        ? _state(
                            _search.text.isNotEmpty
                                ? 'No matching projects'
                                : 'No projects in this view',
                            _search.text.isNotEmpty
                                ? 'Try a different project name.'
                                : 'Choose another status filter to view your projects.',
                          )
                        : RefreshIndicator(
                            onRefresh: _model.load,
                            child: ListView.builder(
                              padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                              itemCount: visible.length,
                              itemBuilder: (_, index) =>
                                  _projectCard(visible[index]),
                            ),
                          ),
                  ),
                ],
              ),
        floatingActionButton: _model.isSignedIn
            ? FloatingActionButton.extended(
                key: const Key('new-project-button'),
                onPressed: _openForm,
                icon: const Icon(Icons.add),
                label: const Text('New Project'),
              )
            : null,
        bottomNavigationBar: widget.showBottomNavigation
            ? SkillTrackBottomNavigation(
                badgeController:
                    widget.badgeController ??
                    (_fallbackBadge ??= NotificationBadgeController(null)),
                onProject: () {},
                onNotifications: () => AppRouter.notifications(context),
                onUnavailable: (name) =>
                    _snack('$name is not available in this prototype.'),
              )
            : null,
      );
    },
  );
}

class _SignInDialog extends StatefulWidget {
  const _SignInDialog({required this.viewModel});

  final ProjectDashboardViewModel viewModel;

  @override
  State<_SignInDialog> createState() => _SignInDialogState();
}

class _SignInDialogState extends State<_SignInDialog> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final ok = await widget.viewModel.signIn(_email.text, _password.text);
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context);
    } else {
      setState(() {
        _busy = false;
        _error = widget.viewModel.errorMessage ?? 'Unable to sign in';
      });
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Sign in to SkillTrack'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: _email,
          keyboardType: TextInputType.emailAddress,
          autofillHints: const [AutofillHints.email],
          decoration: const InputDecoration(labelText: 'Email'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _password,
          obscureText: true,
          autofillHints: const [AutofillHints.password],
          onSubmitted: (_) => _submit(),
          decoration: const InputDecoration(labelText: 'Password'),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
      ],
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _busy ? null : _submit,
        child: _busy ? const Text('Signing in…') : const Text('Sign in'),
      ),
    ],
  );
}
