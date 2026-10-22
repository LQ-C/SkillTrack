import 'package:flutter/material.dart';

import '../../../app/app_theme.dart';

class ProjectProgressCard extends StatelessWidget {
  const ProjectProgressCard({
    super.key,
    required this.progress,
    required this.completed,
    required this.total,
    required this.onTap,
  });
  final double progress;
  final int completed, total;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.fromLTRB(16, 8, 16, 16),
    child: InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Project Progress',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                AnimatedSwitcher(
                  duration: AppTheme.motionDuration(context),
                  child: Text(
                    '${(progress * 100).round()}%',
                    key: ValueKey((progress * 100).round()),
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: progress),
              duration: AppTheme.motionDuration(context),
              curve: AppTheme.transitionCurve,
              builder: (context, value, child) => LinearProgressIndicator(
                value: value,
                minHeight: 8,
                borderRadius: BorderRadius.circular(8),
                backgroundColor: Theme.of(context).colorScheme.primaryContainer,
              ),
            ),
            const SizedBox(height: 10),
            AnimatedSwitcher(
              duration: AppTheme.motionDuration(context),
              child: Text(
                '$completed of $total tasks completed',
                key: ValueKey('$completed/$total'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
