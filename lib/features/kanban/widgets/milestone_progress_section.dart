import 'package:flutter/material.dart';

import '../viewmodels/kanban_view_model.dart';

/// Progress uses the full loaded task set, independently of visible filters.
class MilestoneProgressSection extends StatelessWidget {
  const MilestoneProgressSection({super.key, required this.viewModel});
  final KanbanViewModel viewModel;

  @override
  Widget build(BuildContext context) => ExpansionTile(
    key: const PageStorageKey('milestone-progress'),
    title: const Text('Milestones'),
    dense: true,
    children: [
      ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 160),
        child: ListView(
          key: const PageStorageKey('milestone-progress-scroll'),
          primary: false,
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          children: [
            for (final milestone in viewModel.availableMilestones)
              Builder(
                builder: (context) {
                  final progress = viewModel.milestoneProgress(milestone.id);
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          milestone.title,
                          style: Theme.of(context).textTheme.labelLarge,
                        ),
                        Text(
                          progress.total == 0
                              ? 'No tasks'
                              : '${progress.completed}/${progress.total} completed',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        if (progress.total > 0) ...[
                          const SizedBox(height: 4),
                          LinearProgressIndicator(
                            value: progress.completed / progress.total,
                          ),
                        ],
                      ],
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    ],
  );
}
