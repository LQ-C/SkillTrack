import 'package:flutter/material.dart';

import '../../../app/router/app_router.dart';

import '../models/kanban_sort.dart';
import '../viewmodels/kanban_view_model.dart';

class SortSheet extends StatelessWidget {
  const SortSheet({super.key, required this.viewModel});
  final KanbanViewModel viewModel;
  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Sort tasks', style: Theme.of(context).textTheme.titleLarge),
          ...KanbanSort.values.map(
            (sort) => ListTile(
              selected: sort == viewModel.activeSort,
              selectedColor: Theme.of(context).colorScheme.primary,
              selectedTileColor: Theme.of(
                context,
              ).colorScheme.primaryContainer.withValues(alpha: .5),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              title: Text(sort.label),
              trailing: sort == viewModel.activeSort
                  ? const Icon(Icons.check)
                  : null,
              onTap: () {
                viewModel.setSort(sort);
                AppRouter.back(context);
              },
            ),
          ),
        ],
      ),
    ),
  );
}
