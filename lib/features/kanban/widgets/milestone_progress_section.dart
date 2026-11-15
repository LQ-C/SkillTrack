import 'package:flutter/material.dart';
import '../../../app/app_theme.dart';
import '../viewmodels/kanban_view_model.dart';

/// Uses the full task set from the ViewModel, independently of board filters.
class MilestoneProgressSection extends StatelessWidget {
  const MilestoneProgressSection({super.key, required this.viewModel});
  final KanbanViewModel viewModel;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final duration = AppTheme.motionDuration(
      context,
      const Duration(milliseconds: 220),
    );
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
      side: BorderSide(color: theme.colorScheme.primary.withValues(alpha: .18)),
    );
    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) => Card(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        shape: shape,
        clipBehavior: Clip.antiAlias,
        child: ExpansionTile(
          key: const PageStorageKey('milestone-progress'),
          shape: const Border(),
          collapsedShape: const Border(),
          tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
          childrenPadding: EdgeInsets.zero,
          expansionAnimationStyle: AnimationStyle(
            duration: duration,
            reverseDuration: duration,
            curve: Curves.easeInOut,
          ),
          iconColor: theme.colorScheme.primary,
          collapsedIconColor: theme.colorScheme.primary,
          title: Text(
            'Milestones · ${viewModel.availableMilestones.length}',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          subtitle: Text(
            '${viewModel.completedMilestoneCount} of ${viewModel.availableMilestones.length} milestones completed',
            style: theme.textTheme.bodySmall,
          ),
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 160),
              child: ListView(
                key: const PageStorageKey('milestone-progress-scroll'),
                primary: false,
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                children: [
                  if (viewModel.availableMilestones.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Text('No milestones yet.'),
                    ),
                  for (final milestone in viewModel.availableMilestones)
                    Builder(
                      key: ValueKey(milestone.id),
                      builder: (context) {
                        final progress = viewModel.milestoneCompletion(
                          milestone.id,
                        );
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Icon(
                                  progress.isComplete
                                      ? Icons.check_circle
                                      : Icons.radio_button_unchecked,
                                  size: 18,
                                  color: progress.isComplete
                                      ? theme.colorScheme.primary
                                      : theme.colorScheme.outline,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      milestone.title,
                                      style: theme.textTheme.labelLarge,
                                    ),
                                    const SizedBox(height: 4),
                                    Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Expanded(
                                          child: Text(
                                            progress.total == 0
                                                ? '0/0 tasks · No tasks'
                                                : '${progress.completed}/${progress.total} tasks',
                                            style: theme.textTheme.bodySmall,
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          '${(progress.fraction * 100).round()}%',
                                          style: theme.textTheme.labelMedium
                                              ?.copyWith(
                                                color:
                                                    theme.colorScheme.primary,
                                              ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 6),
                                    TweenAnimationBuilder<double>(
                                      tween: Tween(
                                        begin: 0,
                                        end: progress.fraction,
                                      ),
                                      duration: duration,
                                      curve: Curves.easeInOut,
                                      builder: (context, value, _) =>
                                          LinearProgressIndicator(
                                            value: value,
                                            minHeight: 4,
                                            borderRadius: BorderRadius.circular(
                                              4,
                                            ),
                                            color: theme.colorScheme.primary,
                                            backgroundColor: theme
                                                .colorScheme
                                                .primaryContainer,
                                          ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
