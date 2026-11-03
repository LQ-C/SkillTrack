import 'package:flutter/material.dart';

import '../../../app/widgets/app_content.dart';
import '../../../core/errors/app_exception.dart';
import '../../projects/models/project_milestone.dart';
import '../../../core/utils/date_formatter.dart';

import '../../../app/router/app_router.dart';
import '../models/kanban_status.dart';
import '../models/kanban_task.dart';
import '../models/task_priority.dart';
import '../utils/kanban_colors.dart';
import '../viewmodels/kanban_view_model.dart';
import 'checklist_section.dart';
import 'task_tag_chip.dart';
import 'task_tag_color_picker.dart';

class TaskFormSheet extends StatefulWidget {
  const TaskFormSheet({super.key, required this.viewModel, this.task});
  final KanbanViewModel viewModel;
  final KanbanTask? task;

  @override
  State<TaskFormSheet> createState() => _TaskFormSheetState();
}

class _TaskFormSheetState extends State<TaskFormSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _title, _description;
  final _checklistInput = TextEditingController();
  final List<String> _checklist = [];
  final List<bool> _checked = [];
  late KanbanStatus _status;
  late TaskPriority _priority;
  late DateTime? _deadline;
  String? _milestoneId;
  late bool _hasTime;
  late Set<String> _tagIds;
  bool _moreOptions = false;
  bool _isShowingDialog = false;
  bool _isLeaving = false;

  @override
  void initState() {
    super.initState();
    final task = widget.task;
    _title = TextEditingController(text: task?.title);
    _description = TextEditingController(text: task?.description);
    _status = task?.status ?? KanbanStatus.todo;
    _priority = task?.priority ?? TaskPriority.medium;
    _deadline = task?.deadline == null
        ? null
        : DateFormatter.malaysiaTime(task!.deadline!);
    _milestoneId = task?.milestoneId;
    _hasTime = task?.hasDeadlineTime ?? false;
    _tagIds = task?.tags.map((tag) => tag.id).toSet() ?? {};
  }

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    _checklistInput.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_isLeaving ||
        widget.viewModel.isSaving ||
        widget.viewModel.isCreatingMilestone ||
        !_formKey.currentState!.validate()) {
      return;
    }
    final availableIds = widget.viewModel.availableTags
        .map((tag) => tag.id)
        .toSet();
    final selectedTagIds = _tagIds.intersection(availableIds).toList();
    final task = widget.task;
    final deadline = _deadline == null
        ? null
        : _hasTime
        ? DateFormatter.fromMalaysia(_deadline!)
        : DateFormatter.endOfDateUtc(_deadline!);
    final ok = task == null
        ? await widget.viewModel.createTask(
            title: _title.text,
            description: _description.text,
            status: _status,
            priority: _priority,
            deadline: deadline,
            deadlineHasTime: _deadline == null ? null : _hasTime,
            tagIds: selectedTagIds,
            milestoneId: _milestoneId,
            checklist: [
              ..._checklist,
              if (_checklistInput.text.trim().isNotEmpty) _checklistInput.text,
            ],
          )
        : await widget.viewModel.updateTask(
            task,
            title: _title.text,
            description: _description.text,
            status: _status,
            priority: _priority,
            deadline: deadline,
            deadlineHasTime: _deadline == null ? null : _hasTime,
            tagIds: selectedTagIds,
            milestoneId: _milestoneId,
            clearMilestone: _milestoneId == null,
          );
    if (ok && mounted) {
      setState(() => _isLeaving = true);
      AppRouter.back(context, true);
    }
  }

  Future<void> _createMilestone() async {
    if (_isShowingDialog || !widget.viewModel.canCreateMilestone) return;
    setState(() => _isShowingDialog = true);
    try {
      final created = await showDialog<ProjectMilestone>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _CreateMilestoneDialog(viewModel: widget.viewModel),
      );
      if (created != null && mounted) {
        setState(() => _milestoneId = created.id);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Milestone saved. It stays saved if you cancel this task.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isShowingDialog = false);
    }
  }

  Widget _milestoneSelector() => ListenableBuilder(
    listenable: widget.viewModel,
    builder: (context, child) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DropdownButtonFormField<String>(
          key: const Key('task-milestone'),
          initialValue: _milestoneId ?? '',
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Milestone'),
          items: [
            const DropdownMenuItem(value: '', child: Text('No milestone')),
            for (final milestone in widget.viewModel.availableMilestones)
              DropdownMenuItem(
                value: milestone.id,
                child: Text(milestone.title, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: widget.viewModel.isSaving || _isShowingDialog
              ? null
              : (id) => setState(() => _milestoneId = id == '' ? null : id),
        ),
        TextButton.icon(
          key: const Key('create-milestone-button'),
          onPressed: _isShowingDialog || !widget.viewModel.canCreateMilestone
              ? null
              : _createMilestone,
          icon: const Icon(Icons.add),
          label: const Text('Create milestone'),
        ),
      ],
    ),
  );

  Future<void> _createTag() async {
    if (_isShowingDialog || widget.viewModel.isSaving) return;
    setState(() => _isShowingDialog = true);
    try {
      final created = await showTaskTagEditor(context, widget.viewModel);
      if (created != null && mounted) {
        setState(() => _tagIds.add(created.id));
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Tag created')));
      }
    } finally {
      if (mounted) setState(() => _isShowingDialog = false);
    }
  }

  Future<void> _pickDate() async {
    if (_isShowingDialog || widget.viewModel.isSaving) return;
    setState(() => _isShowingDialog = true);
    try {
      final selected = await showDatePicker(
        context: context,
        initialDate: _deadline ?? DateFormatter.today(),
        firstDate: DateTime(2020),
        lastDate: DateTime(2100),
      );
      if (selected != null && mounted) {
        setState(() {
          final old = _deadline;
          _deadline = DateTime.utc(
            selected.year,
            selected.month,
            selected.day,
            _hasTime ? old?.hour ?? 0 : 0,
            _hasTime ? old?.minute ?? 0 : 0,
          );
        });
      }
    } finally {
      if (mounted) setState(() => _isShowingDialog = false);
    }
  }

  Future<void> _pickTime() async {
    if (_isShowingDialog || widget.viewModel.isSaving) return;
    setState(() => _isShowingDialog = true);
    try {
      final selected = await showTimePicker(
        context: context,
        initialTime: _hasTime && _deadline != null
            ? TimeOfDay.fromDateTime(_deadline!)
            : TimeOfDay.fromDateTime(
                DateFormatter.malaysiaTime(DateTime.now()),
              ),
      );
      if (selected != null && mounted) {
        setState(() {
          final date = _deadline ?? DateFormatter.today();
          _deadline = DateTime.utc(
            date.year,
            date.month,
            date.day,
            selected.hour,
            selected.minute,
          );
          _hasTime = true;
        });
      }
    } finally {
      if (mounted) setState(() => _isShowingDialog = false);
    }
  }

  void _addChecklistItem() {
    final value = _checklistInput.text.trim();
    if (value.isEmpty) return;
    setState(() {
      _checklist.add(value);
      _checked.add(false);
      _checklistInput.clear();
    });
  }

  String _dateLabel(BuildContext context) {
    final date = _deadline;
    if (date == null) return 'No deadline';
    if (DateUtils.isSameDay(date, DateFormatter.today())) return 'Today';
    return MaterialLocalizations.of(context).formatMediumDate(date);
  }

  Widget _statusSelector(ThemeData theme) => Container(
    padding: const EdgeInsets.all(4),
    decoration: BoxDecoration(
      color: theme.colorScheme.surface,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: theme.colorScheme.outlineVariant),
    ),
    child: Row(
      children: [
        for (final status in KanbanStatus.values)
          Expanded(
            child: Semantics(
              button: true,
              selected: _status == status,
              child: InkWell(
                key: Key('status-${status.value}'),
                borderRadius: BorderRadius.circular(12),
                onTap: () => setState(() => _status = status),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOut,
                  constraints: const BoxConstraints(minHeight: 48),
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  decoration: BoxDecoration(
                    color: _status == status
                        ? KanbanColors.status(status).withValues(alpha: .13)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      status.label,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: _status == status
                            ? KanbanColors.status(status)
                            : theme.colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );

  Widget _deadlineRow(ThemeData theme) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: theme.colorScheme.surface,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: theme.colorScheme.outlineVariant),
    ),
    child: Row(
      children: [
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(
            Icons.calendar_month_outlined,
            color: theme.colorScheme.onPrimaryContainer,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: InkWell(
            onTap: _isShowingDialog ? null : _pickDate,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Deadline',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  Text(
                    _dateLabel(context),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        TextButton(
          onPressed: _isShowingDialog ? null : _pickTime,
          child: Text(
            _hasTime && _deadline != null
                ? TimeOfDay.fromDateTime(_deadline!).format(context)
                : 'No time',
          ),
        ),
        if (_deadline != null)
          IconButton(
            tooltip: 'Clear deadline',
            onPressed: () => setState(() {
              _deadline = null;
              _hasTime = false;
            }),
            icon: const Icon(Icons.close, size: 20),
          ),
      ],
    ),
  );

  Widget _tagRow(ThemeData theme) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('Tags', style: theme.textTheme.titleSmall),
      const SizedBox(height: 8),
      SizedBox(
        height: 54,
        child: ListenableBuilder(
          listenable: widget.viewModel,
          builder: (context, child) => ListView(
            scrollDirection: Axis.horizontal,
            children: [
              for (final tag in widget.viewModel.availableTags) ...[
                TaskTagChip(
                  tag: tag,
                  selected: _tagIds.contains(tag.id),
                  onPressed: () => setState(() {
                    if (_tagIds.contains(tag.id)) {
                      _tagIds.remove(tag.id);
                    } else {
                      _tagIds.add(tag.id);
                    }
                  }),
                ),
                const SizedBox(width: 8),
              ],
              ActionChip(
                label: const Text('+ New Tag'),
                onPressed: _isShowingDialog ? null : _createTag,
              ),
            ],
          ),
        ),
      ),
    ],
  );

  Widget _inputCard(ThemeData theme) => Container(
    decoration: BoxDecoration(
      color: theme.colorScheme.surface,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: theme.colorScheme.outlineVariant),
    ),
    child: Column(
      children: [
        TextFormField(
          key: const Key('task-title-field'),
          controller: _title,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            hintText: 'Task title',
            suffixIcon: Icon(Icons.title),
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: UnderlineInputBorder(),
            errorBorder: UnderlineInputBorder(),
            fillColor: Colors.transparent,
          ),
          validator: (value) =>
              value?.trim().isEmpty ?? true ? 'Task title is required' : null,
        ),
        Divider(height: 1, color: theme.colorScheme.outlineVariant),
        TextFormField(
          controller: _description,
          minLines: 3,
          maxLines: 6,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            hintText: 'Description or notes',
            suffixIcon: Icon(Icons.notes_outlined),
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: UnderlineInputBorder(),
            fillColor: Colors.transparent,
          ),
        ),
        Divider(height: 1, color: theme.colorScheme.outlineVariant),
        InkWell(
          borderRadius: const BorderRadius.vertical(
            bottom: Radius.circular(18),
          ),
          onTap: () => ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                widget.task == null
                    ? 'Add attachments after creating the task.'
                    : 'Add attachments from task details.',
              ),
            ),
          ),
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Icon(Icons.attach_file),
                SizedBox(width: 12),
                Expanded(child: Text('Add attachment')),
                Icon(Icons.add),
              ],
            ),
          ),
        ),
      ],
    ),
  );

  Widget _moreOptionsSection(ThemeData theme) {
    final content = _moreOptions
        ? Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Priority', style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final priority in TaskPriority.values)
                      ChoiceChip(
                        label: Text(priority.label),
                        selectedColor: KanbanColors.priority(
                          priority,
                        ).withValues(alpha: .12),
                        checkmarkColor: KanbanColors.priority(priority),
                        labelStyle: theme.textTheme.labelLarge?.copyWith(
                          color: _priority == priority
                              ? KanbanColors.priority(priority)
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                        selected: _priority == priority,
                        onSelected: (_) => setState(() => _priority = priority),
                      ),
                  ],
                ),
                const SizedBox(height: 18),
                Text('Checklist', style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                if (widget.task == null) ...[
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          key: const Key('checklist-item-input'),
                          controller: _checklistInput,
                          onSubmitted: (_) => _addChecklistItem(),
                          decoration: const InputDecoration(
                            hintText: 'Checklist item',
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filledTonal(
                        tooltip: 'Add Item',
                        onPressed: _addChecklistItem,
                        icon: const Icon(Icons.add),
                      ),
                    ],
                  ),
                  for (var index = 0; index < _checklist.length; index++)
                    Row(
                      children: [
                        Checkbox(
                          value: _checked[index],
                          onChanged: (value) =>
                              setState(() => _checked[index] = value ?? false),
                        ),
                        Expanded(child: Text(_checklist[index])),
                        IconButton(
                          tooltip: 'Remove checklist item',
                          onPressed: () => setState(() {
                            _checklist.removeAt(index);
                            _checked.removeAt(index);
                          }),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                ] else
                  ListenableBuilder(
                    listenable: widget.viewModel,
                    builder: (context, child) {
                      final current =
                          widget.viewModel.allTasks
                              .where((item) => item.id == widget.task!.id)
                              .firstOrNull ??
                          widget.task!;
                      return ChecklistSection(
                        task: current,
                        viewModel: widget.viewModel,
                      );
                    },
                  ),
              ],
            ),
          )
        : const SizedBox(width: double.infinity);
    if (MediaQuery.disableAnimationsOf(context)) return content;
    return AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeInOutCubic,
      alignment: Alignment.topCenter,
      child: content,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isNew = widget.task == null;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Back',
          onPressed: () => AppRouter.back(context),
          icon: const Icon(Icons.arrow_back),
        ),
        actions: [
          PopupMenuButton<String>(
            tooltip: 'Task options',
            onSelected: (value) {
              if (value == 'clear-time' && !widget.viewModel.isSaving) {
                setState(() => _hasTime = false);
              }
              if (value == 'reset') {
                setState(() {
                  _title.clear();
                  _description.clear();
                  _status = KanbanStatus.todo;
                  _priority = TaskPriority.medium;
                  _deadline = null;
                  _hasTime = false;
                  _tagIds.clear();
                  _checklist.clear();
                  _checked.clear();
                  _checklistInput.clear();
                });
              }
            },
            itemBuilder: (_) => [
              if (_deadline != null && _hasTime)
                const PopupMenuItem(
                  value: 'clear-time',
                  child: Text('Remove deadline time'),
                ),
              const PopupMenuItem(value: 'reset', child: Text('Clear form')),
            ],
          ),
        ],
      ),
      body: AppContent(
        child: Form(
          key: _formKey,
          child: SafeArea(
            top: false,
            bottom: false,
            child: SingleChildScrollView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isNew ? 'Add New Task' : 'Edit Task',
                    style: theme.textTheme.headlineLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    isNew
                        ? 'Plan the next step in your learning journey.'
                        : 'Update your learning task.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 24),
                  _statusSelector(theme),
                  const SizedBox(height: 22),
                  _deadlineRow(theme),
                  const SizedBox(height: 22),
                  _milestoneSelector(),
                  const SizedBox(height: 16),
                  _tagRow(theme),
                  const SizedBox(height: 18),
                  _inputCard(theme),
                  const SizedBox(height: 22),
                  Center(
                    child: FilledButton.tonalIcon(
                      onPressed: () =>
                          setState(() => _moreOptions = !_moreOptions),
                      icon: Icon(
                        _moreOptions ? Icons.expand_less : Icons.expand_more,
                      ),
                      label: const Text('More Options'),
                    ),
                  ),
                  _moreOptionsSection(theme),
                ],
              ),
            ),
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isNew && widget.viewModel.boardId == null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    'Create a project board to save tasks.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ListenableBuilder(
                listenable: widget.viewModel,
                builder: (context, child) => Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.viewModel.errorMessage != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Semantics(
                          liveRegion: true,
                          child: Text(
                            widget.viewModel.errorMessage!,
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.error,
                            ),
                          ),
                        ),
                      ),
                    SizedBox(
                      height: 56,
                      child: FilledButton(
                        key: const Key('save-task-button'),
                        onPressed:
                            _isLeaving ||
                                widget.viewModel.isSaving ||
                                (isNew && widget.viewModel.boardId == null)
                            ? null
                            : _submit,
                        style: FilledButton.styleFrom(
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(18),
                          ),
                        ),
                        child: widget.viewModel.isSaving
                            ? Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Text(isNew ? 'Creating…' : 'Saving…'),
                                ],
                              )
                            : Text(isNew ? 'Create Task' : 'Save Changes'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CreateMilestoneDialog extends StatefulWidget {
  const _CreateMilestoneDialog({required this.viewModel});
  final KanbanViewModel viewModel;
  @override
  State<_CreateMilestoneDialog> createState() => _CreateMilestoneDialogState();
}

class _CreateMilestoneDialogState extends State<_CreateMilestoneDialog> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    if (widget.viewModel.isCreatingMilestone ||
        !_form.currentState!.validate()) {
      return;
    }
    setState(() => _error = null);
    final created = await widget.viewModel.createMilestone(_name.text);
    if (!mounted) return;
    if (created != null) {
      AppRouter.back(context, created);
    } else {
      setState(
        () => _error =
            widget.viewModel.milestoneError ??
            AppErrorMessages.createMilestoneFailed,
      );
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.viewModel,
    builder: (context, child) {
      final pending = widget.viewModel.isCreatingMilestone;
      return PopScope(
        canPop: !pending,
        child: AlertDialog(
          title: const Text('Create milestone'),
          content: SingleChildScrollView(
            child: Form(
              key: _form,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextFormField(
                    key: const Key('milestone-name-field'),
                    controller: _name,
                    autofocus: true,
                    enabled: !pending,
                    validator: (value) =>
                        ProjectMilestone.validateTitle(value ?? ''),
                    decoration: const InputDecoration(
                      labelText: 'Milestone name',
                    ),
                    onChanged: (_) {
                      if (_error != null) setState(() => _error = null);
                    },
                    textInputAction: TextInputAction.done,
                    onFieldSubmitted: (_) => _create(),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Saved immediately, even if you cancel the task form.',
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: pending ? null : () => AppRouter.back(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const Key('confirm-milestone-button'),
              onPressed: pending || !widget.viewModel.canCreateMilestone
                  ? null
                  : _create,
              child: Text(pending ? 'Creating…' : 'Create'),
            ),
          ],
        ),
      );
    },
  );
}
