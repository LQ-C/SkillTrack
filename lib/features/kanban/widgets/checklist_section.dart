import 'package:flutter/material.dart';

import '../../../app/router/app_router.dart';

import '../models/kanban_task.dart';
import '../models/task_checklist_item.dart';
import '../viewmodels/kanban_view_model.dart';

class ChecklistSection extends StatefulWidget {
  const ChecklistSection({
    super.key,
    required this.task,
    required this.viewModel,
  });
  final KanbanTask task;
  final KanbanViewModel viewModel;
  @override
  State<ChecklistSection> createState() => _ChecklistSectionState();
}

class _ChecklistSectionState extends State<ChecklistSection> {
  final _controller = TextEditingController();
  bool _isEditing = false;
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _edit(TaskChecklistItem item) async {
    if (_isEditing || widget.viewModel.isSaving) return;
    setState(() => _isEditing = true);
    try {
      var enteredTitle = item.title;
      final title = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Edit checklist item'),
          content: TextFormField(
            initialValue: item.title,
            autofocus: true,
            onChanged: (value) => enteredTitle = value,
          ),
          actions: [
            TextButton(
              onPressed: () => AppRouter.back(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => AppRouter.back(dialogContext, enteredTitle),
              child: const Text('Save'),
            ),
          ],
        ),
      );
      if (title != null && mounted) {
        await widget.viewModel.updateChecklistItem(item, title);
      }
    } finally {
      if (mounted) setState(() => _isEditing = false);
    }
  }

  Future<void> _add() async {
    if (widget.viewModel.isSaving) return;
    if (await widget.viewModel.createChecklistItem(
          widget.task.id,
          _controller.text,
        ) &&
        mounted) {
      _controller.clear();
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.viewModel,
    builder: (context, child) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Checklist (${widget.task.checklistCompletedCount}/${widget.task.checklistTotalCount})',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        ReorderableListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          itemCount: widget.task.checklistItems.length,
          onReorder: (oldIndex, newIndex) {
            if (widget.viewModel.isSaving || _isEditing) return;
            if (newIndex > oldIndex) newIndex--;
            widget.viewModel.reorderChecklistItems(
              widget.task.id,
              oldIndex,
              newIndex,
            );
          },
          itemBuilder: (context, index) {
            final item = widget.task.checklistItems[index];
            return Row(
              key: ValueKey(item.id),
              children: [
                Expanded(
                  child: CheckboxListTile(
                    value: item.isCompleted,
                    title: Text(item.title),
                    contentPadding: EdgeInsets.zero,
                    onChanged: widget.viewModel.isSaving || _isEditing
                        ? null
                        : (_) => widget.viewModel.toggleChecklistItem(item),
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: 'Checklist item actions',
                  enabled: !widget.viewModel.isSaving && !_isEditing,
                  onSelected: (action) => action == 'edit'
                      ? _edit(item)
                      : widget.viewModel.deleteChecklistItem(item),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'edit', child: Text('Edit')),
                    PopupMenuItem(value: 'delete', child: Text('Delete')),
                  ],
                ),
                ReorderableDragStartListener(
                  index: index,
                  enabled: !widget.viewModel.isSaving && !_isEditing,
                  child: const Tooltip(
                    message: 'Drag to reorder checklist item',
                    child: SizedBox(
                      width: 44,
                      height: 48,
                      child: Icon(Icons.drag_handle),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _controller,
                decoration: const InputDecoration(
                  hintText: 'Add checklist item',
                ),
              ),
            ),
            IconButton(
              tooltip: 'Add checklist item',
              icon: const Icon(Icons.add),
              onPressed: widget.viewModel.isSaving ? null : _add,
            ),
          ],
        ),
      ],
    ),
  );
}
