import 'package:flutter/material.dart';

import '../../../core/utils/date_formatter.dart';
import '../models/task_activity.dart';

class ActivityTimeline extends StatefulWidget {
  const ActivityTimeline({super.key, required this.activities});

  final List<TaskActivity> activities;

  @override
  State<ActivityTimeline> createState() => _ActivityTimelineState();
}

class _ActivityTimelineState extends State<ActivityTimeline> {
  final _headingKey = GlobalKey();
  bool _isExpanded = false;

  Future<void> _toggle() async {
    if (_isExpanded) {
      final heading = _headingKey.currentContext;
      if (heading != null) {
        await Scrollable.ensureVisible(
          heading,
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 250),
          curve: Curves.easeInOut,
          alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart,
        );
      }
      if (!mounted) return;
    }
    setState(() => _isExpanded = !_isExpanded);
  }

  @override
  Widget build(BuildContext context) {
    final sorted = [...widget.activities]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final initial = sorted.take(3).toList();
    final remaining = sorted.skip(3).toList();
    final hiddenCount = remaining.length;
    final toggleLabel = _isExpanded
        ? 'Show less'
        : 'Show $hiddenCount more ${hiddenCount == 1 ? 'activity' : 'activities'}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Activity',
          key: _headingKey,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        if (sorted.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('No activity recorded yet.'),
          ),
        for (final activity in initial)
          _ActivityRow(key: ValueKey(activity.id), activity: activity),
        _remainingActivities(remaining),
        if (hiddenCount > 0)
          SizedBox(
            width: double.infinity,
            child: TextButton.icon(
              key: const Key('activity-toggle'),
              onPressed: _toggle,
              style: TextButton.styleFrom(
                minimumSize: const Size(44, 44),
                alignment: Alignment.centerLeft,
              ),
              icon: Icon(
                _isExpanded
                    ? Icons.keyboard_arrow_up
                    : Icons.keyboard_arrow_down,
              ),
              label: Text(toggleLabel),
            ),
          ),
      ],
    );
  }

  Widget _remainingActivities(List<TaskActivity> remaining) {
    final rows = Column(
      children: [
        if (_isExpanded)
          for (final activity in remaining)
            _ActivityRow(key: ValueKey(activity.id), activity: activity),
      ],
    );
    if (MediaQuery.disableAnimationsOf(context)) return rows;
    return AnimatedSize(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeInOut,
      alignment: Alignment.topCenter,
      child: rows,
    );
  }
}

class _ActivityRow extends StatelessWidget {
  const _ActivityRow({super.key, required this.activity});

  final TaskActivity activity;

  @override
  Widget build(BuildContext context) {
    final local = activity.createdAt.toLocal();
    final time = MaterialLocalizations.of(context).formatTimeOfDay(
      TimeOfDay.fromDateTime(local),
      alwaysUse24HourFormat: false,
    );
    final description = _description(activity);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2, right: 12),
            child: Icon(
              _icon(activity.action),
              size: 20,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _label(activity),
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                if (description != null)
                  Text(
                    description,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                Text(
                  '${DateFormatter.short(local)} · $time',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String _label(TaskActivity activity) => switch (activity.action) {
  'created' => 'Task created',
  'updated' => 'Task updated',
  'moved' => 'Moved to ${_status(activity.newValues['status'])}',
  'completed' => 'Task completed',
  'reopened' => 'Task reopened',
  'checklist_updated' => 'Checklist updated',
  'tag_added' => 'Tag added',
  'tag_removed' => 'Tag removed',
  'attachment_added' => 'Attachment added',
  'attachment_removed' => 'Attachment removed',
  'archived' => 'Task archived',
  'restored' => 'Task restored',
  _ => _readable(activity.action),
};

String _status(Object? value) => switch (value) {
  'todo' => 'To-Do',
  'in_progress' => 'In Progress',
  'completed' => 'Completed',
  _ => 'another column',
};

String _readable(String value) {
  final words = value.replaceAll('_', ' ').trim();
  if (words.isEmpty) return 'Activity recorded';
  return words[0].toUpperCase() + words.substring(1);
}

String? _description(TaskActivity activity) {
  final values = activity.action == 'attachment_removed'
      ? activity.oldValues
      : activity.newValues;
  if (activity.action == 'updated' && values['title'] is String) {
    return 'Title: ${values['title']}';
  }
  if (activity.action.startsWith('attachment_') &&
      values['file_name'] is String) {
    return values['file_name'] as String;
  }
  return null;
}

IconData _icon(String action) => switch (action) {
  'created' => Icons.add_circle_outline,
  'completed' => Icons.task_alt,
  'reopened' => Icons.replay,
  'moved' => Icons.swap_horiz,
  'checklist_updated' => Icons.checklist,
  'tag_added' || 'tag_removed' => Icons.label_outline,
  'attachment_added' || 'attachment_removed' => Icons.attach_file,
  'archived' => Icons.archive_outlined,
  'restored' => Icons.unarchive_outlined,
  _ => Icons.history,
};
