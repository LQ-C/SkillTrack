import 'package:flutter/material.dart';

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
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _edit(TaskChecklistItem item) async {
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
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, enteredTitle),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (title != null) await widget.viewModel.updateChecklistItem(item, title);
  }

  @override
  Widget build(BuildContext context) => Column(
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
                  onChanged: (_) => widget.viewModel.toggleChecklistItem(item),
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'Checklist item actions',
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
              decoration: const InputDecoration(hintText: 'Add checklist item'),
            ),
          ),
          IconButton(
            tooltip: 'Add checklist item',
            icon: const Icon(Icons.add),
            onPressed: () async {
              if (await widget.viewModel.createChecklistItem(
                widget.task.id,
                _controller.text,
              )) {
                _controller.clear();
              }
            },
          ),
        ],
      ),
    ],
  );
}
