import 'package:flutter/material.dart';

import '../../../app/router/app_router.dart';
import '../../../core/utils/date_formatter.dart';
import '../../kanban/models/task_priority.dart';
import '../models/generated_task_draft.dart';

Future<GeneratedTaskDraft?> showGeneratedTaskEditSheet(
  BuildContext context, {
  required GeneratedTaskDraft task,
  required DateTime startDate,
  required DateTime endDate,
  String? Function(GeneratedTaskDraft)? onSave,
}) => showModalBottomSheet<GeneratedTaskDraft>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (_) => _GeneratedTaskEditSheet(
    task: task,
    startDate: startDate,
    endDate: endDate,
    onSave: onSave,
  ),
);

class _GeneratedTaskEditSheet extends StatefulWidget {
  const _GeneratedTaskEditSheet({
    required this.task,
    required this.startDate,
    required this.endDate,
    this.onSave,
  });

  final GeneratedTaskDraft task;
  final DateTime startDate;
  final DateTime endDate;
  final String? Function(GeneratedTaskDraft)? onSave;

  @override
  State<_GeneratedTaskEditSheet> createState() =>
      _GeneratedTaskEditSheetState();
}

class _GeneratedTaskEditSheetState extends State<_GeneratedTaskEditSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _title;
  late final TextEditingController _description;
  final _newItem = TextEditingController();
  final _items = <TextEditingController>[];
  final _removedItems = <TextEditingController>[];
  late String _priority;
  late DateTime _deadline;
  String? _checklistError;
  bool _isPickingDate = false;
  bool _isLeaving = false;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.task.title);
    _description = TextEditingController(text: widget.task.description);
    _priority = widget.task.priority;
    final start = DateUtils.dateOnly(widget.startDate);
    final end = DateUtils.dateOnly(widget.endDate);
    final current = DateUtils.dateOnly(widget.task.deadline);
    _deadline = current.isBefore(start)
        ? start
        : current.isAfter(end)
        ? end
        : current;
    _items.addAll(
      widget.task.checklist.map((item) => TextEditingController(text: item)),
    );
  }

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    _newItem.dispose();
    for (final item in _items) {
      item.dispose();
    }
    for (final item in _removedItems) {
      item.dispose();
    }
    super.dispose();
  }

  Future<void> _pickDate() async {
    if (_isPickingDate) return;
    setState(() => _isPickingDate = true);
    try {
      final selected = await showDatePicker(
        context: context,
        initialDate: _deadline,
        firstDate: DateUtils.dateOnly(widget.startDate),
        lastDate: DateUtils.dateOnly(widget.endDate),
      );
      if (selected != null && mounted) {
        setState(() => _deadline = DateUtils.dateOnly(selected));
      }
    } finally {
      if (mounted) setState(() => _isPickingDate = false);
    }
  }

  void _addItem() {
    final value = _newItem.text.trim();
    if (value.isEmpty) return;
    if (_items.length >= 5 ||
        value.length > 150 ||
        _items.any(
          (item) => item.text.trim().toLowerCase() == value.toLowerCase(),
        )) {
      setState(
        () => _checklistError =
            'Use up to five unique checklist items of 150 characters or fewer.',
      );
      return;
    }
    setState(() {
      _items.add(TextEditingController(text: value));
      _newItem.clear();
      _checklistError = null;
    });
  }

  void _save() {
    if (_isLeaving) return;
    if (!_formKey.currentState!.validate()) return;
    final items = [
      for (final item in _items) item.text.trim(),
      if (_newItem.text.trim().isNotEmpty) _newItem.text.trim(),
    ].where((item) => item.isNotEmpty).toList();
    if (items.isEmpty ||
        items.length > 5 ||
        items.any((item) => item.length > 150) ||
        items.map((item) => item.toLowerCase()).toSet().length !=
            items.length) {
      setState(
        () => _checklistError =
            'Add 1–5 unique checklist items of 150 characters or fewer.',
      );
      return;
    }
    final updated = widget.task.copyWith(
      title: _title.text.trim(),
      description: _description.text.trim(),
      priority: _priority,
      deadline: _deadline,
      checklist: items,
    );
    final error = widget.onSave?.call(updated);
    if (error != null) {
      setState(() => _checklistError = error);
      return;
    }
    _isLeaving = true;
    AppRouter.back(context, updated);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: FractionallySizedBox(
        heightFactor: .85,
        child: Form(
          key: _formKey,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 12, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Edit generated task',
                        style: theme.textTheme.titleLarge,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      onPressed: () => AppRouter.back(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                  children: [
                    TextFormField(
                      key: const Key('generated-edit-title'),
                      controller: _title,
                      maxLength: 150,
                      decoration: const InputDecoration(labelText: 'Title'),
                      validator: (value) => (value?.trim().isEmpty ?? true)
                          ? 'Enter a title.'
                          : null,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      key: const Key('generated-edit-description'),
                      controller: _description,
                      maxLength: 1000,
                      minLines: 2,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        labelText: 'Description',
                      ),
                      validator: (value) => (value?.trim().isEmpty ?? true)
                          ? 'Enter a description.'
                          : null,
                    ),
                    const SizedBox(height: 16),
                    Text('Priority', style: theme.textTheme.titleSmall),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final priority in TaskPriority.values)
                          ChoiceChip(
                            label: Text(priority.label),
                            selected: _priority == priority.name,
                            onSelected: (_) =>
                                setState(() => _priority = priority.name),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      key: const Key('generated-edit-deadline'),
                      onPressed: _isPickingDate ? null : _pickDate,
                      icon: const Icon(Icons.calendar_today_outlined),
                      label: Text(
                        'Deadline: ${DateFormatter.short(_deadline)}',
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text('Checklist', style: theme.textTheme.titleSmall),
                    for (var index = 0; index < _items.length; index++)
                      Row(
                        key: ObjectKey(_items[index]),
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _items[index],
                              maxLength: 150,
                              decoration: InputDecoration(
                                labelText: 'Item ${index + 1}',
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Remove checklist item',
                            onPressed: () => setState(
                              () => _removedItems.add(_items.removeAt(index)),
                            ),
                            icon: const Icon(Icons.close),
                          ),
                        ],
                      ),
                    if (_items.length < 5)
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              key: const Key('generated-new-checklist-item'),
                              controller: _newItem,
                              maxLength: 150,
                              decoration: const InputDecoration(
                                labelText: 'New checklist item',
                              ),
                              onSubmitted: (_) => _addItem(),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Add checklist item',
                            onPressed: _addItem,
                            icon: const Icon(Icons.add),
                          ),
                        ],
                      ),
                    if (_checklistError != null)
                      Text(
                        _checklistError!,
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                  ],
                ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                  child: SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: FilledButton(
                      key: const Key('save-generated-edit'),
                      onPressed: _save,
                      child: const Text('Save changes'),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
