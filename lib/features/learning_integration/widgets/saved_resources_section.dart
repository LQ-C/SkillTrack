import 'package:flutter/material.dart';
import '../models/resource_recommendation.dart';
import '../view_models/task_bookmarks_view_model.dart';

class BookmarkButton extends StatelessWidget {
  const BookmarkButton({
    super.key,
    required this.model,
    required this.resource,
  });
  final TaskBookmarksViewModel model;
  final ResourceRecommendation resource;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: model,
    builder: (context, _) => IconButton(
      tooltip: model.contains(resource.resourceId)
          ? 'Remove saved resource'
          : 'Save resource to task',
      isSelected: model.contains(resource.resourceId),
      onPressed:
          !model.active ||
              !model.loaded ||
              model.isLoading ||
              model.busy(resource.resourceId)
          ? null
          : () => model.toggle(resource),
      icon: model.busy(resource.resourceId)
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.bookmark_border),
      selectedIcon: model.busy(resource.resourceId)
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.bookmark),
    ),
  );
}

class SavedResourcesSection extends StatelessWidget {
  const SavedResourcesSection({super.key, required this.model});
  final TaskBookmarksViewModel model;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: model,
    builder: (context, _) => Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Saved resources',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (model.isLoading) const LinearProgressIndicator(),
            if (model.errorMessage != null) ...[
              Text(model.errorMessage!),
              TextButton(onPressed: model.retry, child: const Text('Retry')),
            ],
            if (model.loaded && model.items.isEmpty)
              const Text('No saved resources yet.'),
            for (final resource in model.items)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(resource.title),
                subtitle: Text(
                  [
                    resource.type,
                    resource.summary,
                  ].where((s) => s.isNotEmpty).join(' · '),
                ),
                trailing: BookmarkButton(model: model, resource: resource),
              ),
          ],
        ),
      ),
    ),
  );
}
