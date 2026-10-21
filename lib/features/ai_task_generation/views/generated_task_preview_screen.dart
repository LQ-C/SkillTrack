import 'package:flutter/material.dart';

import '../../../app/router/app_router.dart';
import '../../kanban/utils/kanban_colors.dart';
import '../../../core/utils/date_formatter.dart';
import '../../kanban/models/task_priority.dart';
import '../models/task_generation_request.dart';
import '../view_models/generated_task_preview_state.dart';
import '../models/generated_task_draft.dart';
import '../widgets/generated_task_edit_sheet.dart';

class GeneratedTaskPreviewScreen extends StatefulWidget {
  const GeneratedTaskPreviewScreen({super.key, required this.viewModel});

  final GeneratedTaskPreviewState viewModel;

  @override
  State<GeneratedTaskPreviewScreen> createState() =>
      _GeneratedTaskPreviewScreenState();
}

class _GeneratedTaskPreviewScreenState
    extends State<GeneratedTaskPreviewScreen> {
  final _feedback = TextEditingController();
  bool _isShowingOverlay = false;
  bool _isLeaving = false;
  bool get _busy =>
      _isLeaving ||
      _isShowingOverlay ||
      viewModel.isConfirmingGeneratedTasks ||
      viewModel.isRevisingGeneratedTasks;
  final _taskKeys = <Key>[];
  GeneratedTaskPreviewState get viewModel => widget.viewModel;

  @override
  void dispose() {
    _feedback.dispose();
    super.dispose();
  }

  Future<void> _confirm(BuildContext context) async {
    if (_busy) return;
    final result = await viewModel.confirmGeneratedTasks();
    if (context.mounted && result != null) {
      setState(() => _isLeaving = true);
      AppRouter.back(context, result);
    }
  }

  void _cancel(BuildContext context) {
    if (_busy) {
      return;
    }
    setState(() => _isLeaving = true);
    viewModel.cancelGeneratedTaskPreview();
    AppRouter.back(context);
  }

  Future<void> _edit(
    BuildContext context,
    int index,
    GeneratedTaskDraft task,
  ) async {
    if (_busy) return;
    setState(() => _isShowingOverlay = true);
    try {
      await showGeneratedTaskEditSheet(
        context,
        task: task,
        startDate: viewModel.generationStartDate,
        endDate: viewModel.generationEndDate,
        onSave: (updated) => viewModel.updateGeneratedTask(index, updated)
            ? null
            : viewModel.errorMessage ?? 'Unable to update this task.',
      );
    } finally {
      if (mounted) setState(() => _isShowingOverlay = false);
    }
  }

  Future<void> _remove(BuildContext context, int index) async {
    if (_busy) return;
    setState(() => _isShowingOverlay = true);
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Remove generated task?'),
          content: const Text('This task has not been saved yet.'),
          actions: [
            TextButton(
              onPressed: () => AppRouter.back(context, false),
              child: const Text('Keep task'),
            ),
            TextButton(
              onPressed: () => AppRouter.back(context, true),
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error,
              ),
              child: const Text('Remove'),
            ),
          ],
        ),
      );
      if (confirmed == true && mounted) {
        _taskKeys.removeAt(index);
        viewModel.removeGeneratedTask(index);
      }
    } finally {
      if (mounted) setState(() => _isShowingOverlay = false);
    }
  }

  void _reorder(int oldIndex, int newIndex) {
    if (_busy || !viewModel.canCustomizeGeneratedTasks) return;
    final key = _taskKeys.removeAt(oldIndex);
    _taskKeys.insert(newIndex > oldIndex ? newIndex - 1 : newIndex, key);
    viewModel.reorderGeneratedTask(oldIndex, newIndex);
  }

  Future<void> _revise(BuildContext context) async {
    if (_busy) return;
    FocusScope.of(context).unfocus();
    if (await viewModel.reviseGeneratedTasks(_feedback.text) && mounted) {
      _feedback.clear();
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: viewModel,
    builder: (context, child) {
      final tasks = viewModel.pendingGeneratedTasks;
      while (_taskKeys.length < tasks.length) {
        _taskKeys.add(UniqueKey());
      }
      if (_taskKeys.length > tasks.length) {
        _taskKeys.removeRange(tasks.length, _taskKeys.length);
      }
      final saving = viewModel.isConfirmingGeneratedTasks;
      final revising = viewModel.isRevisingGeneratedTasks;
      final busy = saving || revising || _isLeaving;
      final canCustomize =
          !busy && !_isShowingOverlay && viewModel.canCustomizeGeneratedTasks;
      final append = viewModel.generationMode == TaskGenerationMode.append;
      final theme = Theme.of(context);
      return PopScope<Object?>(
        canPop: !busy,
        onPopInvokedWithResult: (didPop, result) {
          if (didPop) viewModel.cancelGeneratedTaskPreview();
        },
        child: Scaffold(
          appBar: AppBar(
            title: Text(
              append ? 'Review Additional Tasks' : 'Review Generated Tasks',
            ),
            leading: IconButton(
              tooltip: 'Back',
              onPressed: busy ? null : () => _cancel(context),
              icon: const Icon(Icons.arrow_back),
            ),
          ),
          body: SafeArea(
            bottom: false,
            child: Stack(
              children: [
                AbsorbPointer(
                  absorbing: busy,
                  child: ReorderableListView.builder(
                    key: const Key('generated-task-preview-list'),
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                    buildDefaultDragHandles: false,
                    itemCount: tasks.length,
                    onReorder: _reorder,
                    header: Padding(
                      padding: const EdgeInsets.only(bottom: 20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            append
                                ? 'These tasks will be added to your existing project. Your current tasks will not be changed.'
                                : 'Review the generated plan before creating your project.',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            '${tasks.length} generated ${tasks.length == 1 ? 'task' : 'tasks'}',
                            style: theme.textTheme.titleMedium,
                          ),
                          if (tasks.isEmpty)
                            const Padding(
                              padding: EdgeInsets.only(top: 20),
                              child: Text(
                                'No tasks in this preview. Cancel to return.',
                              ),
                            ),
                        ],
                      ),
                    ),
                    footer: _revisionSection(
                      theme,
                      enabled: canCustomize && tasks.isNotEmpty,
                    ),
                    itemBuilder: (context, index) {
                      final task = tasks[index];
                      return Padding(
                        key: _taskKeys[index],
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _PreviewCard(
                          task: task,
                          number: index + 1,
                          onEdit: canCustomize
                              ? () => _edit(context, index, task)
                              : null,
                          onRemove: canCustomize
                              ? () => _remove(context, index)
                              : null,
                          dragHandle: ReorderableDelayedDragStartListener(
                            index: index,
                            enabled: canCustomize,
                            child: Tooltip(
                              message: 'Hold to reorder task',
                              child: Icon(
                                Icons.drag_handle,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                if (revising)
                  Positioned.fill(
                    child: ColoredBox(
                      color: theme.colorScheme.surface.withValues(alpha: .82),
                      child: const Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CircularProgressIndicator(),
                            SizedBox(height: 16),
                            Text('Revising plan…'),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          bottomNavigationBar: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (viewModel.errorMessage != null) ...[
                    Text(
                      viewModel.errorMessage!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final cancel = OutlinedButton(
                        key: const Key('cancel-generated-tasks-button'),
                        onPressed: busy ? null : () => _cancel(context),
                        child: const Text('Cancel'),
                      );
                      final confirm = FilledButton(
                        key: const Key('confirm-generated-tasks-button'),
                        onPressed: busy || _isShowingOverlay || tasks.isEmpty
                            ? null
                            : () => _confirm(context),
                        child: Text(
                          saving
                              ? append
                                    ? 'Adding tasks to your project…'
                                    : 'Creating project…'
                              : append
                              ? 'Add Tasks'
                              : 'Confirm & Create',
                        ),
                      );
                      if (constraints.maxWidth < 360 ||
                          MediaQuery.textScalerOf(context).scale(1) > 1.3) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SizedBox(height: 52, child: confirm),
                            const SizedBox(height: 8),
                            SizedBox(height: 52, child: cancel),
                          ],
                        );
                      }
                      return Row(
                        children: [
                          Expanded(child: SizedBox(height: 52, child: cancel)),
                          const SizedBox(width: 12),
                          Expanded(child: SizedBox(height: 52, child: confirm)),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );

  Widget _revisionSection(ThemeData theme, {required bool enabled}) => Padding(
    padding: const EdgeInsets.only(top: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Revise this plan', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'The revised plan may replace your current preview changes.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('revision-feedback-field'),
          controller: _feedback,
          enabled: enabled,
          minLines: 2,
          maxLines: 4,
          maxLength: 1000,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
            labelText: 'What should change?',
            hintText: 'Add more testing tasks and make the plan easier.',
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: OutlinedButton.icon(
            key: const Key('revise-generated-plan-button'),
            onPressed: enabled && _feedback.text.trim().isNotEmpty
                ? () => _revise(context)
                : null,
            icon: const Icon(Icons.auto_awesome_outlined),
            label: const Text('Revise Plan'),
          ),
        ),
      ],
    ),
  );
}

class _PreviewCard extends StatelessWidget {
  const _PreviewCard({
    required this.task,
    required this.number,
    required this.onEdit,
    required this.onRemove,
    required this.dragHandle,
  });

  final GeneratedTaskDraft task;
  final int number;
  final VoidCallback? onEdit;
  final VoidCallback? onRemove;
  final Widget dragHandle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final priority = TaskPriority.fromValue(task.priority);
    final color = KanbanColors.priority(priority);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Task $number',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Chip(
                  label: Text(priority.label),
                  backgroundColor: color.withValues(alpha: .10),
                  side: BorderSide.none,
                  labelStyle: theme.textTheme.labelLarge?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                IconButton(
                  tooltip: 'Edit generated task',
                  color: theme.colorScheme.primary,
                  onPressed: onEdit,
                  icon: const Icon(Icons.edit_outlined),
                ),
                IconButton(
                  tooltip: 'Remove generated task',
                  color: theme.colorScheme.error,
                  onPressed: onRemove,
                  icon: const Icon(Icons.delete_outline),
                ),
                dragHandle,
              ],
            ),
            Text(task.title, style: theme.textTheme.titleMedium),
            if (task.description.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                task.description,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 12),
            Text(
              'Deadline: ${DateFormatter.short(task.deadline)}',
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
            ),
            const Divider(height: 24),
            Text(
              'Checklist (${task.checklist.length})',
              style: theme.textTheme.titleSmall,
            ),
            if (task.checklist.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text('No checklist generated'),
              )
            else
              for (final item in task.checklist)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.radio_button_unchecked,
                        size: 18,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          item,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
          ],
        ),
      ),
    );
  }
}
