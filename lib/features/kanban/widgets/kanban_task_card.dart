import 'package:flutter/material.dart';

import '../utils/kanban_colors.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/utils/date_formatter.dart';
import '../models/kanban_status.dart';
import '../models/kanban_task.dart';
import 'task_tag_chip.dart';
import 'task_stagnation_indicator.dart';

enum TaskCardAction {
  details,
  edit,
  todo,
  inProgress,
  completed,
  duplicate,
  archive,
  delete,
}

class KanbanTaskCard extends StatelessWidget {
  const KanbanTaskCard({
    super.key,
    required this.task,
    required this.onTap,
    required this.onAction,
  });
  final KanbanTask task;
  final VoidCallback? onTap;
  final ValueChanged<TaskCardAction>? onAction;

  @override
  Widget build(BuildContext context) {
    final deadlineColor = task.isCompleted
        ? KanbanColors.status(KanbanStatus.completed)
        : task.isOverdue
        ? Theme.of(context).colorScheme.error
        : task.isDueSoon
        ? AppColors.warning
        : Theme.of(context).colorScheme.onSurfaceVariant;
    final deadlineIcon = task.isCompleted
        ? Icons.check_circle_outline
        : task.isOverdue
        ? Icons.warning_amber_rounded
        : Icons.calendar_today_outlined;
    return Card(
      key: Key('task-${task.id}'),
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
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
                  PopupMenuButton<TaskCardAction>(
                    tooltip: 'Task actions',
                    enabled: onAction != null,
                    onSelected: onAction,
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                        value: TaskCardAction.details,
                        child: Text('View details'),
                      ),
                      const PopupMenuItem(
                        value: TaskCardAction.edit,
                        child: Text('Edit task'),
                      ),
                      if (task.status != KanbanStatus.todo)
                        const PopupMenuItem(
                          value: TaskCardAction.todo,
                          child: Text('Move to To-Do'),
                        ),
                      if (task.status != KanbanStatus.inProgress)
                        const PopupMenuItem(
                          value: TaskCardAction.inProgress,
                          child: Text('Move to In Progress'),
                        ),
                      if (task.status != KanbanStatus.completed)
                        const PopupMenuItem(
                          value: TaskCardAction.completed,
                          child: Text('Move to Completed'),
                        ),
                      const PopupMenuItem(
                        value: TaskCardAction.duplicate,
                        child: Text('Duplicate'),
                      ),
                      const PopupMenuItem(
                        value: TaskCardAction.archive,
                        child: Text('Archive'),
                      ),
                      const PopupMenuItem(
                        value: TaskCardAction.delete,
                        child: Text('Delete permanently'),
                      ),
                    ],
                  ),
                ],
              ),
              if (task.description.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  task.description,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ],
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(deadlineIcon, size: 16, color: deadlineColor),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          task.isCompleted
                              ? 'Completed · ${DateFormatter.short(task.deadline)}'
                              : task.isOverdue
                              ? 'Overdue · ${DateFormatter.short(task.deadline)}'
                              : task.isDueSoon
                              ? 'Due soon · ${DateFormatter.short(task.deadline)}'
                              : DateFormatter.short(task.deadline),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: deadlineColor,
                            fontSize: 12,
                            fontWeight: task.isOverdue ? FontWeight.w700 : null,
                          ),
                        ),
                      ),
                    ],
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: KanbanColors.priority(
                        task.priority,
                      ).withValues(alpha: .10),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      task.priority.label,
                      style: TextStyle(
                        fontSize: 12,
                        color: KanbanColors.priority(task.priority),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (task.shouldShowStagnation)
                    TaskStagnationIndicator(task: task, compact: true),
                ],
              ),
              if (task.tags.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final tag in task.tags.take(3))
                      TaskTagChip(tag: tag, compact: true),
                    if (task.tags.length > 3)
                      Chip(label: Text('+${task.tags.length - 3}')),
                  ],
                ),
              ],
              if (task.checklistTotalCount > 0) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Icon(Icons.checklist, size: 16),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        '${task.checklistCompletedCount}/${task.checklistTotalCount} checklist items',
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
