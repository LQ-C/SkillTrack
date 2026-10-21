import 'package:flutter/material.dart';

import '../../../app/router/app_router.dart';

import '../models/kanban_filter.dart';
import '../models/kanban_status.dart';
import '../models/task_priority.dart';
import '../utils/kanban_colors.dart';
import '../viewmodels/kanban_view_model.dart';
import 'task_tag_chip.dart';

class FilterSheet extends StatefulWidget {
  const FilterSheet({super.key, required this.viewModel});
  final KanbanViewModel viewModel;
  @override
  State<FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<FilterSheet> {
  late Set<KanbanStatus> statuses;
  late Set<TaskPriority> priorities;
  late Set<String> tagIds;
  late bool overdueOnly, completedOnly;
  DateTime? start, end;
  bool _isPickingDate = false;
  @override
  void initState() {
    super.initState();
    final filter = widget.viewModel.activeFilter;
    statuses = {...filter.statuses};
    priorities = {...filter.priorities};
    tagIds = {...filter.tagIds};
    overdueOnly = filter.overdueOnly;
    completedOnly = filter.completedOnly;
    start = filter.deadlineStart;
    end = filter.deadlineEnd;
  }

  Future<void> _pickDate(bool from) async {
    if (_isPickingDate) return;
    setState(() => _isPickingDate = true);
    try {
      final date = await showDatePicker(
        context: context,
        initialDate: (from ? start : end) ?? DateTime.now(),
        firstDate: DateTime(2020),
        lastDate: DateTime(2100),
      );
      if (date != null && mounted) {
        setState(() {
          if (from) {
            start = date;
          } else {
            end = date;
          }
        });
      }
    } finally {
      if (mounted) setState(() => _isPickingDate = false);
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: ListView(
        shrinkWrap: true,
        children: [
          Text('Filter tasks', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          Text('Status', style: Theme.of(context).textTheme.titleSmall),
          Wrap(
            spacing: 6,
            children: KanbanStatus.values
                .map(
                  (status) => FilterChip(
                    label: Text(status.label),
                    selectedColor: KanbanColors.status(
                      status,
                    ).withValues(alpha: .13),
                    checkmarkColor: KanbanColors.status(status),
                    labelStyle: Theme.of(context).textTheme.labelLarge
                        ?.copyWith(
                          color: statuses.contains(status)
                              ? KanbanColors.status(status)
                              : Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                    selected: statuses.contains(status),
                    onSelected: (selected) => setState(() {
                      selected ? statuses.add(status) : statuses.remove(status);
                    }),
                  ),
                )
                .toList(),
          ),
          const SizedBox(height: 8),
          Text('Priority', style: Theme.of(context).textTheme.titleSmall),
          Wrap(
            spacing: 6,
            children: TaskPriority.values
                .map(
                  (priority) => FilterChip(
                    label: Text(priority.label),
                    selectedColor: KanbanColors.priority(
                      priority,
                    ).withValues(alpha: .12),
                    checkmarkColor: KanbanColors.priority(priority),
                    labelStyle: Theme.of(context).textTheme.labelLarge
                        ?.copyWith(
                          color: priorities.contains(priority)
                              ? KanbanColors.priority(priority)
                              : Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                    selected: priorities.contains(priority),
                    onSelected: (selected) => setState(() {
                      selected
                          ? priorities.add(priority)
                          : priorities.remove(priority);
                    }),
                  ),
                )
                .toList(),
          ),
          const SizedBox(height: 8),
          Text('Tags', style: Theme.of(context).textTheme.titleSmall),
          Wrap(
            spacing: 6,
            children: widget.viewModel.availableTags
                .map(
                  (tag) => TaskTagChip(
                    tag: tag,
                    selected: tagIds.contains(tag.id),
                    onPressed: () => setState(() {
                      tagIds.contains(tag.id)
                          ? tagIds.remove(tag.id)
                          : tagIds.add(tag.id);
                    }),
                  ),
                )
                .toList(),
          ),
          SwitchListTile(
            title: const Text('Overdue only'),
            value: overdueOnly,
            onChanged: (value) => setState(() => overdueOnly = value),
          ),
          SwitchListTile(
            title: const Text('Completed only'),
            value: completedOnly,
            onChanged: (value) => setState(() => completedOnly = value),
          ),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _isPickingDate ? null : () => _pickDate(true),
                  child: Text(
                    start == null
                        ? 'From date'
                        : '${start!.day}/${start!.month}/${start!.year}',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: _isPickingDate ? null : () => _pickDate(false),
                  child: Text(
                    end == null
                        ? 'To date'
                        : '${end!.day}/${end!.month}/${end!.year}',
                  ),
                ),
              ),
            ],
          ),
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            spacing: 8,
            runSpacing: 8,
            children: [
              TextButton(
                onPressed: () {
                  widget.viewModel.clearFilters();
                  AppRouter.back(context);
                },
                child: const Text('Clear all'),
              ),
              FilledButton(
                onPressed: () {
                  widget.viewModel.applyFilter(
                    KanbanFilter(
                      statuses: statuses,
                      priorities: priorities,
                      tagIds: tagIds,
                      overdueOnly: overdueOnly,
                      completedOnly: completedOnly,
                      deadlineStart: start,
                      deadlineEnd: end,
                    ),
                  );
                  AppRouter.back(context);
                },
                child: const Text('Apply filters'),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}
