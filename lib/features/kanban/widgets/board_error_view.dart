import 'package:flutter/material.dart';

class BoardErrorView extends StatelessWidget {
  const BoardErrorView({
    super.key,
    required this.message,
    required this.onRetry,
    this.actionLabel = 'Retry',
    this.description = 'Please check your connection and try again.',
  });
  final String message;
  final VoidCallback onRetry;
  final String actionLabel;
  final String description;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(
            radius: 36,
            backgroundColor: Theme.of(context).colorScheme.errorContainer,
            foregroundColor: Theme.of(context).colorScheme.onErrorContainer,
            child: const Icon(Icons.cloud_off_outlined, size: 36),
          ),
          const SizedBox(height: 12),
          Text(
            'Unable to load the board',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            description,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          FilledButton(onPressed: onRetry, child: Text(actionLabel)),
        ],
      ),
    ),
  );
}
