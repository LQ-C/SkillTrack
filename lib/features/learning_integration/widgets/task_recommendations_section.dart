import 'package:skilltrack/app/router/app_router.dart';
import '../view_models/task_bookmarks_view_model.dart';
import 'saved_resources_section.dart';
import 'package:flutter/material.dart';
import '../view_models/task_recommendations_view_model.dart';

class TaskRecommendationsSection extends StatefulWidget {
  const TaskRecommendationsSection({
    super.key,
    required this.viewModel,
    this.bookmarks,
  });
  final TaskRecommendationsViewModel viewModel;
  final TaskBookmarksViewModel? bookmarks;
  @override
  State<TaskRecommendationsSection> createState() =>
      _TaskRecommendationsSectionState();
}

class _TaskRecommendationsSectionState
    extends State<TaskRecommendationsSection> {
  bool opening = false;
  Future<void> open(String id) async {
    if (opening) return;
    setState(() => opening = true);
    try {
      await AppRouter.resourceDetails(context, id);
    } finally {
      if (mounted) setState(() => opening = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.viewModel,
    builder: (context, _) {
      final model = widget.viewModel;
      if (!model.visible) return const SizedBox.shrink();
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
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Learning resources',
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Refresh recommendations',
                      onPressed: model.isLoading || !model.eligible
                          ? null
                          : model.getRecommendations,
                      icon: const Icon(Icons.refresh_rounded),
                    ),
                  ],
                ),
                Text(
                  'Resources to help with this task',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                if (model.isLoading)
                  Semantics(
                    label: 'Loading learning resources',
                    child: const LinearProgressIndicator(minHeight: 2),
                  ),
                if (model.isLoading && model.items.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text('Loading learning resources…'),
                  ),
                if (model.errorMessage != null) ...[
                  Text(model.errorMessage!, style: theme.textTheme.bodyMedium),
                  TextButton.icon(
                    onPressed: model.isLoading ? null : model.retry,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry'),
                  ),
                ],
                if (!model.isLoading &&
                    model.errorMessage == null &&
                    model.items.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      model.hasRequested
                          ? 'No relevant learning resources found yet.'
                          : 'Tap refresh to find resources for this task.',
                    ),
                  ),
                for (final resource in model.items)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Card(
                      margin: EdgeInsets.zero,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(
                          color: theme.colorScheme.primary.withValues(
                            alpha: .18,
                          ),
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  resource.type == 'Video'
                                      ? Icons.play_circle_outline
                                      : Icons.menu_book_outlined,
                                  size: 20,
                                  color: theme.colorScheme.primary,
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    resource.type,
                                    style: theme.textTheme.labelMedium
                                        ?.copyWith(
                                          color: theme.colorScheme.primary,
                                        ),
                                  ),
                                ),
                                if (widget.bookmarks != null)
                                  BookmarkButton(
                                    model: widget.bookmarks!,
                                    resource: resource,
                                  ),
                              ],
                            ),
                            Text(
                              resource.title,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (resource.summary.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text(
                                resource.summary,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                            const SizedBox(height: 4),
                            TextButton.icon(
                              onPressed: opening
                                  ? null
                                  : () => open(resource.resourceId),
                              iconAlignment: IconAlignment.end,
                              icon: const Icon(Icons.arrow_forward, size: 18),
                              label: const Text('View resource'),
                            ),
                          ],
                        ),
                      ),
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
