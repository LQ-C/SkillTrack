import 'package:flutter/material.dart';

import '../../../app/router/app_router.dart';

import '../../../core/errors/app_exception.dart';
import '../models/task_tag.dart';
import '../utils/task_tag_color_utils.dart';
import '../viewmodels/kanban_view_model.dart';
import 'task_tag_color_picker.dart';

class TagManagementSheet extends StatefulWidget {
  const TagManagementSheet({super.key, required this.viewModel});

  final KanbanViewModel viewModel;

  @override
  State<TagManagementSheet> createState() => _TagManagementSheetState();
}

class _TagManagementSheetState extends State<TagManagementSheet> {
  bool _isShowingDialog = false;
  KanbanViewModel get viewModel => widget.viewModel;

  Future<void> _edit([TaskTag? tag]) async {
    if (_isShowingDialog || viewModel.isSaving) return;
    setState(() => _isShowingDialog = true);
    try {
      await showTaskTagEditor(context, viewModel, tag: tag);
    } finally {
      if (mounted) setState(() => _isShowingDialog = false);
    }
  }

  Future<void> _delete(BuildContext context, TaskTag tag) async {
    if (_isShowingDialog || viewModel.isSaving) return;
    setState(() => _isShowingDialog = true);
    try {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Delete tag?'),
          content: Text(
            'Remove “${tag.name}” from every task? Tasks will remain.',
          ),
          actions: [
            TextButton(
              onPressed: () => AppRouter.back(dialogContext, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => AppRouter.back(dialogContext, true),
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error,
              ),
              child: const Text('Delete'),
            ),
          ],
        ),
      );
      if (confirm != true || !context.mounted) return;
      final ok = await viewModel.deleteTag(tag.id);
      if (!ok && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              viewModel.errorMessage ?? AppErrorMessages.deleteTagFailed,
            ),
          ),
        );
        viewModel.clearError();
      }
    } finally {
      if (mounted) setState(() => _isShowingDialog = false);
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: ListenableBuilder(
        listenable: viewModel,
        builder: (context, child) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Manage tags', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final tag in viewModel.availableTags)
                    ListTile(
                      key: Key('managed-tag-${tag.id}'),
                      leading: Tooltip(
                        message: 'Edit ${tag.name} color',
                        child: InkWell(
                          onTap: (viewModel.isSaving || _isShowingDialog)
                              ? null
                              : () => _edit(tag),
                          customBorder: const CircleBorder(),
                          child: Container(
                            width: 48,
                            height: 48,
                            padding: const EdgeInsets.all(12),
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: TaskTagColorUtils.base(tag.colorHex),
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: TaskTagColorUtils.border(tag.colorHex),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      title: Text(tag.name),
                      subtitle: Text(TaskTagColorUtils.normalize(tag.colorHex)),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'Edit ${tag.name}',
                            icon: const Icon(Icons.edit_outlined),
                            onPressed: (viewModel.isSaving || _isShowingDialog)
                                ? null
                                : () => _edit(tag),
                          ),
                          IconButton(
                            tooltip: 'Delete ${tag.name}',
                            color: Theme.of(context).colorScheme.error,
                            icon: const Icon(Icons.delete_outline),
                            onPressed: (viewModel.isSaving || _isShowingDialog)
                                ? null
                                : () => _delete(context, tag),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: (viewModel.isSaving || _isShowingDialog)
                  ? null
                  : () => _edit(),
              icon: const Icon(Icons.add),
              label: const Text('Create tag'),
            ),
          ],
        ),
      ),
    ),
  );
}
