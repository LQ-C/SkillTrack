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
  });
  final String taskId;
  final KanbanViewModel viewModel;
  final ValueChanged<KanbanTask> onEdit;
  final bool fullScreen;
  @override
  State<TaskDetailsSheet> createState() => _TaskDetailsSheetState();
}

class _TaskDetailsSheetState extends State<TaskDetailsSheet> {
  late Future<List<TaskActivity>> _activity;
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
