import 'package:flutter/material.dart';
import '../view_models/task_recommendations_view_model.dart';

class TaskRecommendationsSection extends StatelessWidget {
  const TaskRecommendationsSection({super.key, required this.viewModel});
  final TaskRecommendationsViewModel viewModel;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: viewModel,
    builder: (context, _) {
      if (!viewModel.eligible) return const SizedBox.shrink();
      final theme = Theme.of(context);
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Learning resources', style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: viewModel.isLoading
                      ? null
                      : viewModel.getRecommendations,
                  icon: const Icon(Icons.school_outlined),
                  label: const Text('Get Recommendations'),
                ),
                if (viewModel.isLoading)
                  Semantics(
                    label: 'Loading learning resources',
                    child: const LinearProgressIndicator(),
                  )
                else if (viewModel.errorMessage != null) ...[
                  Text(
                    viewModel.errorMessage!,
                    style: theme.textTheme.bodyMedium,
                  ),
                  TextButton.icon(
                    onPressed: viewModel.retry,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry'),
                  ),
                ] else if (viewModel.hasRequested && viewModel.items.isEmpty)
                  const Text('No relevant learning resources found yet.')
                else
                  for (final resource in viewModel.items)
                    Padding(
                      padding: const EdgeInsets.only(top: 8, bottom: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            resource.type,
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: theme.colorScheme.primary,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            resource.title,
                            style: theme.textTheme.titleSmall,
                          ),
                          if (resource.summary.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              resource.summary,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium,
                            ),
                          ],
                        ],
                      ),
                    ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
