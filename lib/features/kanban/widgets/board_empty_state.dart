import 'package:flutter/material.dart';

class BoardEmptyState extends StatelessWidget {
  const BoardEmptyState({super.key, required this.onAction});
  final VoidCallback onAction;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(
            radius: 36,
            backgroundColor: Theme.of(context).colorScheme.primaryContainer,
            foregroundColor: Theme.of(context).colorScheme.onPrimaryContainer,
            child: const Icon(Icons.filter_alt_off, size: 36),
          ),
          const SizedBox(height: 12),
          Text(
            'No matching tasks',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            'Try changing or clearing your filters.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(onPressed: onAction, child: const Text('Clear filters')),
        ],
      ),
    ),
  );
}
