import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/errors/app_exception.dart';
import '../../../app/router/app_router.dart';
import '../../../core/utils/date_formatter.dart';
import '../models/kanban_task.dart';
import '../viewmodels/archived_tasks_view_model.dart';
import '../widgets/board_loading_view.dart';
import '../widgets/task_tag_chip.dart';

class ArchivedTasksScreen extends StatefulWidget {
  const ArchivedTasksScreen({
    super.key,
    required this.viewModel,
    required this.boardId,
    required this.projectName,
  });

  final ArchivedTasksViewModel viewModel;
  final String boardId;
  final String projectName;

  @override
  State<ArchivedTasksScreen> createState() => _ArchivedTasksScreenState();
}

class _ArchivedTasksScreenState extends State<ArchivedTasksScreen> {
  final _search = TextEditingController();
  ({KanbanTask task, int index})? _pendingExit;
  Timer? _exitTimer;
  bool _exitAnimated = false;
  bool _showSearch = false;
  bool _isShowingOverlay = false;

  @override
  void initState() {
    super.initState();
    widget.viewModel.addListener(_showFeedback);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.viewModel.loadArchivedTasks(widget.boardId);
    });
  }

  @override
  void dispose() {
    widget.viewModel.removeListener(_showFeedback);
    _exitTimer?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _showFeedback() {
    final message = widget.viewModel.feedbackMessage;
    if (message == null) return;
    widget.viewModel.clearFeedbackMessage();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Semantics(liveRegion: true, child: Text(message))),
      );
    });
  }

  Future<void> _run(Future<bool> Function() action) async {
    final ok = await action();
    if (!ok && mounted && widget.viewModel.errorMessage != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(widget.viewModel.errorMessage!)));
      widget.viewModel.clearError();
    }
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    required String action,
    bool destructive = false,
  }) async =>
      await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => AppRouter.back(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => AppRouter.back(dialogContext, true),
              style: destructive
                  ? FilledButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.error,
                    )
                  : null,
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _restore(KanbanTask task) async {
    if (_isShowingOverlay ||
        widget.viewModel.isSaving ||
        _pendingExit != null) {
      return;
    }
    setState(() => _isShowingOverlay = true);
    try {
      final confirmed = await _confirm(
        title: 'Restore task?',
        message: 'This task will return to the Kanban Board.',
        action: 'Restore',
      );
      if (confirmed && mounted) {
        await _removeWithMotion(
          task,
          () => widget.viewModel.restoreTask(task.id),
        );
      }
    } finally {
      if (mounted) setState(() => _isShowingOverlay = false);
    }
  }

  Future<void> _restoreAll() async {
    if (_isShowingOverlay ||
        widget.viewModel.isSaving ||
        _pendingExit != null) {
      return;
    }
    setState(() => _isShowingOverlay = true);
    try {
      final confirmed = await _confirm(
        title: 'Restore all tasks?',
        message: 'All archived tasks will return to this Kanban Board.',
        action: 'Restore All',
      );
      if (confirmed && mounted) await _run(widget.viewModel.restoreAllTasks);
    } finally {
      if (mounted) setState(() => _isShowingOverlay = false);
    }
  }

  Future<void> _delete(KanbanTask task) async {
    if (_isShowingOverlay ||
        widget.viewModel.isSaving ||
        _pendingExit != null) {
      return;
    }
    setState(() => _isShowingOverlay = true);
    try {
      final confirmed = await _confirm(
        title: 'Delete task permanently?',
        message:
            'This task and its checklist, attachments, tag connections, '
            'and activity history will be permanently deleted. '
            'This action cannot be undone.',
        action: 'Delete Permanently',
        destructive: true,
      );
      if (confirmed && mounted) {
        await _removeWithMotion(
          task,
          () => widget.viewModel.deleteTaskPermanently(task.id),
        );
      }
    } finally {
      if (mounted) setState(() => _isShowingOverlay = false);
    }
  }

  Future<void> _removeWithMotion(
    KanbanTask task,
    Future<bool> Function() action,
  ) async {
    final index = widget.viewModel.visibleTasks.indexWhere(
      (item) => item.id == task.id,
    );
    setState(() {
      _pendingExit = (task: task, index: index < 0 ? 0 : index);
      _exitAnimated = false;
    });
    final ok = await action();
    if (!mounted) return;
    if (!ok) {
      setState(() => _pendingExit = null);
      if (widget.viewModel.errorMessage != null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(widget.viewModel.errorMessage!)));
        widget.viewModel.clearError();
      }
      return;
    }
    setState(() => _exitAnimated = true);
    _exitTimer?.cancel();
    _exitTimer = Timer(
      MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 260),
      () {
        if (mounted) setState(() => _pendingExit = null);
      },
    );
  }

  Future<void> _details(KanbanTask task) async {
    if (_isShowingOverlay) return;
    setState(() => _isShowingOverlay = true);
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (context) => Padding(
          padding: const EdgeInsets.all(24),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  task.title,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 12),
                if (task.description.isNotEmpty) Text(task.description),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    const Chip(label: Text('Archived')),
                    Chip(label: Text(task.status.label)),
                    Chip(label: Text('${task.priority.label} priority')),
                    Chip(
                      label: Text(
                        'Deadline: ${DateFormatter.short(task.deadline)}',
                      ),
                    ),
                    for (final tag in task.tags) TaskTagChip(tag: tag),
                  ],
                ),
                if (task.checklistTotalCount > 0) ...[
                  const SizedBox(height: 12),
                  Text(
                    'Checklist: ${task.checklistCompletedCount}/'
                    '${task.checklistTotalCount} complete',
                  ),
                ],
                const SizedBox(height: 20),
              ],
            ),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _isShowingOverlay = false);
    }
  }

  Widget _message({
    required IconData icon,
    required String title,
    required String description,
    required String action,
    required VoidCallback onPressed,
  }) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 52),
          const SizedBox(height: 12),
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(description, textAlign: TextAlign.center),
          const SizedBox(height: 20),
          FilledButton(onPressed: onPressed, child: Text(action)),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.viewModel,
    builder: (context, child) {
      final model = widget.viewModel;
      final tasks = model.visibleTasks;
      final displayed = [...tasks];
      final pending = _pendingExit;
      if (pending != null &&
          !displayed.any((task) => task.id == pending.task.id)) {
        displayed.insert(
          pending.index.clamp(0, displayed.length),
          pending.task,
        );
      }
      return Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: 'Back to Board',
            onPressed: () => AppRouter.back(context),
            icon: const Icon(Icons.arrow_back),
          ),
          title: _showSearch
              ? TextField(
                  key: const Key('archived-search'),
                  controller: _search,
                  autofocus: true,
                  onChanged: model.setSearchQuery,
                  decoration: const InputDecoration(
                    hintText: 'Search archived tasks',
                    border: InputBorder.none,
                  ),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Archived Tasks'),
                    Text(
                      widget.projectName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
          actions: [
            IconButton(
              tooltip: _showSearch ? 'Close search' : 'Search archived tasks',
              onPressed: () {
                setState(() => _showSearch = !_showSearch);
                if (!_showSearch) {
                  _search.clear();
                  model.setSearchQuery('');
                }
              },
              icon: Icon(_showSearch ? Icons.close : Icons.search),
            ),
            PopupMenuButton<String>(
              tooltip: 'Archived tasks menu',
              enabled: !model.isSaving && !_isShowingOverlay,
              onSelected: (value) {
                switch (value) {
                  case 'restoreAll':
                    _restoreAll();
                  case 'recent':
                    model.sortRecentlyArchived();
                  case 'title':
                    model.sortByTaskTitle();
                }
              },
              itemBuilder: (_) => [
                if (!model.isEmpty)
                  const PopupMenuItem(
                    value: 'restoreAll',
                    child: Text('Restore all'),
                  ),
                const PopupMenuItem(
                  value: 'recent',
                  child: Text('Sort by recently archived'),
                ),
                const PopupMenuItem(
                  value: 'title',
                  child: Text('Sort by task title'),
                ),
              ],
            ),
          ],
        ),
        body: SafeArea(
          child: model.isLoading
              ? const BoardLoadingView()
              : model.errorMessage != null &&
                    model.isEmpty &&
                    _pendingExit == null
              ? _message(
                  icon: Icons.cloud_off_outlined,
                  title: AppErrorMessages.loadArchivedTasksFailed,
                  description: 'Please check your connection and try again.',
                  action: 'Retry',
                  onPressed: model.retry,
                )
              : model.isEmpty && _pendingExit == null
              ? _message(
                  icon: Icons.archive_outlined,
                  title: 'No archived tasks',
                  description:
                      'Tasks you archive from this board will appear here.',
                  action: 'Return to Board',
                  onPressed: () => AppRouter.back(context),
                )
              : model.isSearchEmpty && _pendingExit == null
              ? _message(
                  icon: Icons.search_off,
                  title: 'No matching archived tasks',
                  description: 'Try a different search term.',
                  action: 'Clear search',
                  onPressed: () {
                    _search.clear();
                    model.setSearchQuery('');
                  },
                )
              : Column(
                  children: [
                    if (model.isSaving)
                      const LinearProgressIndicator(
                        semanticsLabel: 'Saving archived tasks',
                      ),
                    Expanded(
                      child: RefreshIndicator(
                        onRefresh: model.refresh,
                        child: ListView.builder(
                          padding: const EdgeInsets.all(16),
                          itemCount: displayed.length,
                          itemBuilder: (context, index) {
                            final task = displayed[index];
                            final leaving =
                                _exitAnimated &&
                                task.id == _pendingExit?.task.id;
                            return TweenAnimationBuilder<double>(
                              key: ValueKey('archived-row-${task.id}'),
                              tween: Tween(begin: 1, end: leaving ? 0 : 1),
                              duration: MediaQuery.disableAnimationsOf(context)
                                  ? Duration.zero
                                  : const Duration(milliseconds: 260),
                              curve: Curves.easeInCubic,
                              builder: (context, value, child) => ClipRect(
                                child: Align(
                                  heightFactor: value,
                                  child: Opacity(opacity: value, child: child),
                                ),
                              ),
                              child: IgnorePointer(
                                ignoring: leaving,
                                child: _ArchivedTaskCard(
                                  key: Key('archived-task-${task.id}'),
                                  task: task,
                                  isSaving:
                                      model.isSaving ||
                                      _pendingExit != null ||
                                      _isShowingOverlay,
                                  onDetails: _isShowingOverlay
                                      ? null
                                      : () => _details(task),
                                  onRestore: () => _restore(task),
                                  onDelete: () => _delete(task),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      );
    },
  );
}

class _ArchivedTaskCard extends StatelessWidget {
  const _ArchivedTaskCard({
    super.key,
    required this.task,
    required this.isSaving,
    required this.onDetails,
    required this.onRestore,
    required this.onDelete,
  });

  final KanbanTask task;
  final bool isSaving;
  final VoidCallback? onDetails;
  final VoidCallback onRestore;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 12),
    color: Theme.of(context).colorScheme.surfaceContainerLow,
    child: InkWell(
      onTap: onDetails,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.archive_outlined, semanticLabel: 'Archived'),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    task.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: 'Archived task actions',
                  enabled: !isSaving,
                  onSelected: (value) {
                    switch (value) {
                      case 'details':
                        onDetails?.call();
                      case 'restore':
                        onRestore();
                      case 'delete':
                        onDelete();
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: 'details',
                      child: Text('View details'),
                    ),
                    PopupMenuItem(
                      value: 'restore',
                      child: Text('Restore task'),
                    ),
                    PopupMenuItem(
                      value: 'delete',
                      child: Text('Delete permanently'),
                    ),
                  ],
                ),
              ],
            ),
            if (task.description.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                task.description,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                Chip(label: Text(task.status.label)),
                Chip(label: Text('${task.priority.label} priority')),
                Chip(label: Text(DateFormatter.short(task.deadline))),
                for (final tag in task.tags.take(3))
                  TaskTagChip(tag: tag, compact: true),
                if (task.tags.length > 3)
                  Chip(label: Text('+${task.tags.length - 3}')),
                if (task.checklistTotalCount > 0)
                  Chip(
                    label: Text(
                      '${task.checklistCompletedCount}/'
                      '${task.checklistTotalCount} checklist',
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}
