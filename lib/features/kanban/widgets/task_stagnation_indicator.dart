import 'package:flutter/material.dart';

import '../../../core/utils/date_formatter.dart';
import '../../../core/constants/app_constants.dart';
import '../models/kanban_task.dart';

class TaskStagnationIndicator extends StatelessWidget {
  const TaskStagnationIndicator({
    super.key,
    required this.task,
    this.compact = false,
  });

  final KanbanTask task;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (task.isCompleted ||
        task.isArchived ||
        (compact && !task.shouldShowStagnation)) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final color = task.shouldShowStalled
        ? theme.colorScheme.error
        : task.stagnationScore >= 30
        ? AppColors.warning
        : theme.colorScheme.primary;
    final decoration = BoxDecoration(
      color: color.withValues(alpha: task.shouldShowStalled ? .14 : .08),
      borderRadius: BorderRadius.circular(compact ? 20 : 12),
      border: Border.all(
        color: color.withValues(alpha: task.shouldShowStalled ? .5 : .25),
      ),
    );
    if (compact) {
      return Semantics(
        container: true,
        label:
            'Task ${task.stagnationLabel.toLowerCase()}, stagnation score ${task.stagnationScore} out of 100',
        child: ExcludeSemantics(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
            decoration: decoration,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.warning_amber_rounded, size: 16, color: color),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    task.stagnationLabel,
                    style: TextStyle(
                      color: color,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    final activity = task.lastActivityAt?.toLocal();
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: decoration,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                task.shouldShowStalled || task.isAtRisk
                    ? Icons.warning_amber_rounded
                    : Icons.info_outline,
                size: 20,
                color: color,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Stagnation',
                  style: theme.textTheme.titleSmall?.copyWith(color: color),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text('${task.stagnationScore}/100 · ${task.stagnationLabel}'),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: task.stagnationProgress,
            color: color,
            backgroundColor: color.withValues(alpha: .12),
            semanticsLabel:
                'Task ${task.stagnationLabel.toLowerCase()}, stagnation score ${task.stagnationScore} out of 100',
            semanticsValue: '${task.stagnationScore}',
          ),
          const SizedBox(height: 8),
          if (activity == null)
            Text('No activity recorded', style: theme.textTheme.bodySmall)
          else
            Tooltip(
              message:
                  '${DateFormatter.short(activity)} · ${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(activity))}',
              child: Text(
                'Last activity: ${DateFormatter.relative(activity)}',
                style: theme.textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }
}
