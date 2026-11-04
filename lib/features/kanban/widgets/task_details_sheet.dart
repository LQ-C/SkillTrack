import 'package:flutter/material.dart';

import '../../../app/widgets/app_content.dart';

import '../../../core/errors/app_exception.dart';
import '../../../app/router/app_router.dart';
import '../../../core/utils/date_formatter.dart';
import '../models/kanban_task.dart';
import '../models/task_activity.dart';
import '../utils/kanban_colors.dart';
import '../viewmodels/kanban_view_model.dart';
import 'activity_timeline.dart';
import 'attachment_section.dart';
import 'checklist_section.dart';
import 'task_tag_chip.dart';
import 'task_timer_section.dart';

class TaskDetailsSheet extends StatefulWidget {
  const TaskDetailsSheet({
    super.key,
    required this.taskId,
    required this.viewModel,
    required this.onEdit,
    this.fullScreen = false,
    this.showStalledWarning = false,
    this.showRecommendations = false,
    this.resourceTitles = const [],
    this.resourceCount = 0,
  });
  final String taskId;
  final KanbanViewModel viewModel;
  final ValueChanged<KanbanTask>? onEdit;
  final bool fullScreen;
  final bool showStalledWarning;
  final bool showRecommendations;
  final List<String> resourceTitles;
  final int resourceCount;
  @override
  State<TaskDetailsSheet> createState() => _TaskDetailsSheetState();
}

class _TaskDetailsSheetState extends State<TaskDetailsSheet> {
  late Future<List<TaskActivity>> _activity;
  late int _activityVersion;
  bool _resuming = false, _addingProgress = false;
  @override
  void initState() {
    super.initState();
    _activity = widget.viewModel.getTaskActivity(widget.taskId);
    _activityVersion = widget.viewModel.activityVersion;
    widget.viewModel.addListener(_onChanged);
  }

  void _onChanged() {
    if (_activityVersion == widget.viewModel.activityVersion) return;
    _activityVersion = widget.viewModel.activityVersion;
    final activity = widget.viewModel.getTaskActivity(widget.taskId);
    setState(() {
      _activity = activity;
    });
  }

  @override
  void didUpdateWidget(covariant TaskDetailsSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.viewModel == widget.viewModel &&
        oldWidget.taskId == widget.taskId) {
      return;
    }
    oldWidget.viewModel.removeListener(_onChanged);
    widget.viewModel.addListener(_onChanged);
    _activityVersion = widget.viewModel.activityVersion;
    _activity = widget.viewModel.getTaskActivity(widget.taskId);
  }

  @override
  void dispose() {
    widget.viewModel.removeListener(_onChanged);
    super.dispose();
  }

  Future<void> _addProgress() async {
    if (_addingProgress || widget.viewModel.isSaving) return;
    setState(() => _addingProgress = true);
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _ProgressUpdateDialog(
          viewModel: widget.viewModel,
          taskId: widget.taskId,
        ),
      );
    } finally {
      if (mounted) setState(() => _addingProgress = false);
    }
  }

  Future<void> _resume(KanbanTask task) async {
    if (_resuming) return;
    setState(() => _resuming = true);
    try {
      final resumed = await widget.viewModel.resumeTask(task.id);
      if (!mounted) return;
      if (!resumed) {
        _showResumeError();
      }
    } catch (_) {
      if (mounted) _showResumeError();
    } finally {
      if (mounted) setState(() => _resuming = false);
    }
  }

  Future<void> _toggleTimer(KanbanTask task) async {
    final saved = await widget.viewModel.setTaskTimerPaused(
      task.id,
      task.isTracking,
    );
    if (!mounted || saved || widget.viewModel.isSaving) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          widget.viewModel.errorMessage ??
              AppErrorMessages.updateTaskTimerFailed,
        ),
      ),
    );
  }

  void _showResumeError() => ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(content: Text(AppErrorMessages.resumeTaskFailed)),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.viewModel,
    builder: (context, child) {
      final task = widget.viewModel.allTasks
          .where((item) => item.id == widget.taskId)
          .firstOrNull;
      if (task == null) return const Center(child: Text('Task unavailable'));
      final showStalled =
          task.isStalled && !task.isCompleted && !task.isArchived;
      return AppContent(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            16,
            0,
            16,
            MediaQuery.viewInsetsOf(context).bottom + 16,
          ),
          child: SafeArea(
            top: false,
            child: SizedBox(
              height: widget.fullScreen
                  ? MediaQuery.sizeOf(context).height -
                        kToolbarHeight -
                        MediaQuery.paddingOf(context).top
                  : MediaQuery.sizeOf(context).height * .78,
              child: ListView(
                children: [
                  if (showStalled)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Card(
                        margin: EdgeInsets.zero,
                        color: Theme.of(context).colorScheme.tertiaryContainer,
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Icon(
                                    Icons.warning_amber_rounded,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.tertiary,
                                    semanticLabel: 'Warning',
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'Task marked as stalled',
                                          style: Theme.of(
                                            context,
                                          ).textTheme.titleMedium,
                                        ),
                                        const SizedBox(height: 4),
                                        const Text(
                                          'No recent progress was detected.',
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              OutlinedButton.icon(
                                onPressed: _resuming
                                    ? null
                                    : () => _resume(task),
                                icon: _resuming
                                    ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Icon(Icons.play_arrow),
                                label: Text(
                                  _resuming ? 'Resuming…' : 'Resume Task',
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  Card(
                    margin: EdgeInsets.zero,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Text(
                                  task.title,
                                  style: Theme.of(
                                    context,
                                  ).textTheme.headlineSmall,
                                ),
                              ),
                              IconButton(
                                tooltip: 'Edit task',
                                onPressed:
                                    widget.viewModel.isSaving ||
                                        widget.onEdit == null
                                    ? null
                                    : () => widget.onEdit!(task),
                                icon: const Icon(Icons.edit_outlined),
                              ),
                            ],
                          ),
                          if (task.description.isNotEmpty) ...[
                            const SizedBox(height: 12),
                            Text(task.description),
                          ],
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              Chip(
                                label: Text(task.status.label),
                                backgroundColor: KanbanColors.status(
                                  task.status,
                                ).withValues(alpha: .12),
                                labelStyle: TextStyle(
                                  color: KanbanColors.status(task.status),
                                ),
                              ),
                              Chip(
                                label: Text('${task.priority.label} priority'),
                                backgroundColor: KanbanColors.priority(
                                  task.priority,
                                ).withValues(alpha: .10),
                                labelStyle: TextStyle(
                                  color: KanbanColors.priority(task.priority),
                                ),
                              ),
                              Chip(
                                label: Text(
                                  'Deadline: ${DateFormatter.short(task.deadline)}',
                                ),
                              ),
                            ],
                          ),
                          if (task.tags.isNotEmpty) ...[
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: [
                                for (final tag in task.tags)
                                  TaskTagChip(tag: tag),
                              ],
                            ),
                          ],
                          const SizedBox(height: 16),
                          TaskTimerSection(
                            task: task,
                            isSaving: widget.viewModel.isSaving,
                            onToggle: () => _toggleTimer(task),
                          ),
                          const Divider(height: 28),
                          ChecklistSection(
                            task: task,
                            viewModel: widget.viewModel,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  AttachmentSection(task: task, viewModel: widget.viewModel),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      key: const Key('add-progress-update'),
                      onPressed:
                          _addingProgress ||
                              widget.viewModel.isSaving ||
                              task.isArchived ||
                              widget.viewModel.isBoardArchived
                          ? null
                          : _addProgress,
                      icon: const Icon(Icons.edit_note_outlined),
                      label: const Text('Add progress update'),
                    ),
                  ),
                  const Divider(height: 28),
                  FutureBuilder<List<TaskActivity>>(
                    future: _activity,
                    builder: (context, snapshot) => snapshot.hasError
                        ? const Text('Activity unavailable')
                        : ActivityTimeline(
                            activities: snapshot.data ?? const [],
                          ),
                  ),
                  const Divider(height: 28),
                  Text(
                    'Created ${DateFormatter.short(task.createdAt)}',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  Text(
                    'Updated ${DateFormatter.short(task.updatedAt)}',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _ProgressUpdateDialog extends StatefulWidget {
  const _ProgressUpdateDialog({required this.viewModel, required this.taskId});
  final KanbanViewModel viewModel;
  final String taskId;
  @override
  State<_ProgressUpdateDialog> createState() => _ProgressUpdateDialogState();
}

class _ProgressUpdateDialogState extends State<_ProgressUpdateDialog> {
  final _form = GlobalKey<FormState>();
  final _text = TextEditingController();
  String? _error;
  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (widget.viewModel.isSaving || !_form.currentState!.validate()) return;
    setState(() => _error = null);
    final saved = await widget.viewModel.addProgressUpdate(
      widget.taskId,
      _text.text,
    );
    if (!mounted) return;
    if (saved) {
      AppRouter.back(context);
    } else {
      setState(
        () => _error =
            widget.viewModel.errorMessage ??
            AppErrorMessages.saveProgressUpdateFailed,
      );
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.viewModel,
    builder: (context, child) => PopScope(
      canPop: !widget.viewModel.isSaving,
      child: AlertDialog(
        title: const Text('Add progress update'),
        content: SingleChildScrollView(
          child: Form(
            key: _form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  key: const Key('progress-update-text'),
                  controller: _text,
                  autofocus: true,
                  minLines: 3,
                  maxLines: 5,
                  enabled: !widget.viewModel.isSaving,
                  decoration: const InputDecoration(
                    labelText: 'What progress did you make?',
                  ),
                  validator: (value) =>
                      TaskActivity.validateProgressText(value ?? ''),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Semantics(
                      liveRegion: true,
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: widget.viewModel.isSaving
                ? null
                : () => AppRouter.back(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('save-progress-update'),
            onPressed: widget.viewModel.isSaving ? null : _save,
            child: Text(widget.viewModel.isSaving ? 'Saving...' : 'Save'),
          ),
        ],
      ),
    ),
  );
}
