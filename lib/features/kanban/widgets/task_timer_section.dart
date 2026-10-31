import 'dart:async';

import 'package:flutter/material.dart';

import '../models/kanban_status.dart';
import '../models/kanban_task.dart';

class TaskTimerSection extends StatefulWidget {
  const TaskTimerSection({
    super.key,
    required this.task,
    required this.isSaving,
    required this.onToggle,
  });

  final KanbanTask task;
  final bool isSaving;
  final VoidCallback onToggle;

  @override
  State<TaskTimerSection> createState() => _TaskTimerSectionState();
}

class _TaskTimerSectionState extends State<TaskTimerSection>
    with WidgetsBindingObserver {
  Timer? _timer;
  bool _visible = true;
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visible = TickerMode.valuesOf(context).enabled;
    _syncTimer();
  }

  @override
  void didUpdateWidget(covariant TaskTimerSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTimer();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _syncTimer();
    if (_foreground && mounted) setState(() {});
  }

  void _syncTimer() {
    if (!_visible || !_foreground || !widget.task.isTracking) {
      _timer?.cancel();
      _timer = null;
    } else {
      _timer ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    final duration = task.trackedDurationAt(DateTime.now());
    String two(int value) => value.toString().padLeft(2, '0');
    final time =
        '${two(duration.inHours)}:'
        '${two(duration.inMinutes.remainder(60))}:'
        '${two(duration.inSeconds.remainder(60))}';
    final canTrack = task.status == KanbanStatus.inProgress && !task.isArchived;
    final state = task.isTracking
        ? 'Running'
        : canTrack
        ? 'Paused'
        : duration == Duration.zero
        ? 'Not started'
        : 'Saved';
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Tracked time', style: theme.textTheme.titleSmall),
        const SizedBox(height: 6),
        Wrap(
          spacing: 16,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Semantics(
              label: 'Tracked time: $time. $state.',
              excludeSemantics: true,
              child: Text(time, style: theme.textTheme.titleLarge),
            ),
            if (canTrack)
              OutlinedButton.icon(
                key: const Key('task-timer-toggle'),
                onPressed: widget.isSaving ? null : widget.onToggle,
                icon: Icon(task.isTracking ? Icons.pause : Icons.play_arrow),
                label: Text(task.isTracking ? 'Pause timer' : 'Resume timer'),
              ),
          ],
        ),
        Text(
          state,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
