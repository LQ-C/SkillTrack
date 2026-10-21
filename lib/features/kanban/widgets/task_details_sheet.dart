import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/utils/date_formatter.dart';
import '../models/kanban_task.dart';
import '../models/task_activity.dart';
import '../viewmodels/kanban_view_model.dart';
import 'activity_timeline.dart';
import 'attachment_section.dart';
import 'checklist_section.dart';
import 'task_tag_chip.dart';

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
  bool _resuming = false;
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
      return Padding(
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
                      color: AppColors.warning.withValues(alpha: .10),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Icon(
                                  Icons.warning_amber_rounded,
                                  color: AppColors.warning,
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
                              onPressed: _resuming ? null : () => _resume(task),
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
                            Chip(label: Text(task.status.label)),
                            Chip(
                              label: Text('${task.priority.label} priority'),
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
                const Divider(height: 28),
                FutureBuilder<List<TaskActivity>>(
                  future: _activity,
                  builder: (context, snapshot) => snapshot.hasError
                      ? const Text('Activity unavailable')
                      : ActivityTimeline(activities: snapshot.data ?? const []),
                ),
                const Divider(height: 28),
                Text('Created ${DateFormatter.short(task.createdAt)}'),
                Text('Updated ${DateFormatter.short(task.updatedAt)}'),
              ],
            ),
          ),
        ),
      );
    },
  );
}
