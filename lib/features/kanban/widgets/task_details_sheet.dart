import 'package:flutter/material.dart';

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
    this.onResume,
    this.showRecommendations = false,
    this.resourceTitles = const [],
    this.resourceCount = 0,
  });
  final String taskId;
  final KanbanViewModel viewModel;
  final ValueChanged<KanbanTask> onEdit;
  final bool fullScreen;
  final bool showStalledWarning;
  final Future<bool> Function(KanbanTask)? onResume;
  final bool showRecommendations;
  final List<String> resourceTitles;
  final int resourceCount;
  @override
  State<TaskDetailsSheet> createState() => _TaskDetailsSheetState();
}

class _TaskDetailsSheetState extends State<TaskDetailsSheet> {
  late Future<List<TaskActivity>> _activity;
  bool _resumed = false;
  @override
  void initState() {
    super.initState();
    _activity = widget.viewModel.getTaskActivity(widget.taskId);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.viewModel,
    builder: (context, child) {
      final task = widget.viewModel.allTasks
          .where((item) => item.id == widget.taskId)
          .firstOrNull;
      if (task == null) return const Center(child: Text('Task unavailable'));
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
                if (widget.showStalledWarning && !_resumed)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('This task was flagged as stalled.'),
                          const SizedBox(height: 8),
                          TextButton.icon(
                            onPressed: widget.onResume == null
                                ? null
                                : () async {
                                    final ok = await widget.onResume!(task);
                                    if (mounted && ok) {
                                      setState(() => _resumed = true);
                                    }
                                  },
                            icon: const Icon(Icons.play_arrow),
                            label: const Text('Resume Task'),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (widget.showRecommendations)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Recommended Learning Resources',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          if (widget.resourceTitles.isEmpty)
                            Text(
                              widget.resourceCount > 0
                                  ? '${widget.resourceCount} resources were recommended, but their details are unavailable.'
                                  : 'Resource details are unavailable for this alert.',
                            )
                          else
                            for (final title in widget.resourceTitles)
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: const Icon(Icons.menu_book_outlined),
                                title: Text(title),
                              ),
                        ],
                      ),
                    ),
                  ),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        task.title,
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Edit task',
                      onPressed: () => widget.onEdit(task),
                      icon: const Icon(Icons.edit_outlined),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (task.description.isNotEmpty) Text(task.description),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    Chip(label: Text(task.status.label)),
                    Chip(label: Text('${task.priority.label} priority')),
                    Chip(
                      label: Text(
                        'Deadline: ${DateFormatter.short(task.deadline)}',
                      ),
                    ),
                  ],
                ),
                if (task.tags.isNotEmpty)
                  Wrap(
                    spacing: 6,
                    children: task.tags
                        .map((tag) => TaskTagChip(tag: tag))
                        .toList(),
                  ),
                const Divider(height: 28),
                ChecklistSection(task: task, viewModel: widget.viewModel),
                const Divider(height: 28),
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
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: () => widget.onEdit(task),
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('Edit task'),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
