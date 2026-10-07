import 'package:flutter/material.dart';

import '../models/kanban_filter.dart';
import '../models/kanban_status.dart';
import '../models/task_priority.dart';
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
                  onPressed: () async {
                    final date = await showDatePicker(
                      context: context,
                      initialDate: start ?? DateTime.now(),
                      firstDate: DateTime(2020),
                      lastDate: DateTime(2100),
                    );
                    if (date != null && mounted) setState(() => start = date);
                  },
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
                  onPressed: () async {
                    final date = await showDatePicker(
                      context: context,
                      initialDate: end ?? DateTime.now(),
                      firstDate: DateTime(2020),
                      lastDate: DateTime(2100),
                    );
                    if (date != null && mounted) setState(() => end = date);
                  },
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
                  Navigator.pop(context);
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
                  Navigator.pop(context);
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
