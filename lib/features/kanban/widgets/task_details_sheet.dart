import 'package:flutter/material.dart';

import '../../learning_integration/view_models/task_recommendations_view_model.dart';
import '../../learning_integration/widgets/task_recommendations_section.dart';

import '../../../app/widgets/app_content.dart';

import '../../../core/errors/app_exception.dart';
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
    this.recommendations,
    this.showLearningResources = false,
  });
  final String taskId;
  final KanbanViewModel viewModel;
  final ValueChanged<KanbanTask>? onEdit;
  final bool fullScreen;
  final bool showLearningResources;
  final TaskRecommendationsViewModel? recommendations;
  @override
  State<TaskDetailsSheet> createState() => _TaskDetailsSheetState();
}

class _TaskDetailsSheetState extends State<TaskDetailsSheet> {
  late Future<List<TaskActivity>> _activity;
  late int _activityVersion;
  bool _resuming = false;
  final _resourcesKey = GlobalKey();
  @override
  void initState() {
    super.initState();
    _activity = widget.viewModel.getTaskActivity(widget.taskId);
    _activityVersion = widget.viewModel.activityVersion;
    widget.viewModel.addListener(_onChanged);
    if (widget.showLearningResources) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final target = _resourcesKey.currentContext;
        if (mounted &&
            target != null &&
            widget.recommendations?.eligible == true) {
          Scrollable.ensureVisible(target, alignment: 0);
        }
      });
    }
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
                  Card(
                    margin: EdgeInsets.zero,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: AttachmentSection(
                        task: task,
                        viewModel: widget.viewModel,
                      ),
                    ),
                  ),
                  if (widget.recommendations != null) ...[
                    const SizedBox(height: 12),
                    TaskRecommendationsSection(
                      key: _resourcesKey,
                      viewModel: widget.recommendations!,
                    ),
                  ],
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
