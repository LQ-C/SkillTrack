import 'package:flutter/material.dart';

import '../../../app/router/app_router.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/utils/date_formatter.dart';
import '../../kanban/models/task_priority.dart';
import '../../projects/viewmodels/create_project_view_model.dart';
import '../models/generated_task_draft.dart';

class GeneratedTaskPreviewScreen extends StatelessWidget {
  const GeneratedTaskPreviewScreen({super.key, required this.viewModel});

  final CreateProjectViewModel viewModel;

  Future<void> _confirm(BuildContext context) async {
    final project = await viewModel.confirmGeneratedTasks();
    if (context.mounted && project != null) AppRouter.back(context, project);
  }

  void _cancel(BuildContext context) {
    if (!viewModel.isConfirmingGeneratedTasks) AppRouter.back(context);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: viewModel,
    builder: (context, child) {
      final tasks = viewModel.pendingGeneratedTasks;
      final saving = viewModel.isConfirmingGeneratedTasks;
      final theme = Theme.of(context);
      return PopScope<Object?>(
        canPop: !saving,
        onPopInvokedWithResult: (didPop, result) {
          if (didPop) viewModel.cancelGeneratedTaskPreview();
        },
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Review Generated Tasks'),
            leading: IconButton(
              tooltip: 'Back',
              onPressed: saving ? null : () => _cancel(context),
              icon: const Icon(Icons.arrow_back),
            ),
          ),
          body: SafeArea(
            bottom: false,
            child: ListView.builder(
              key: const Key('generated-task-preview-list'),
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
              itemCount: tasks.length + 1,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Review the generated plan before creating your project.',
                          style: theme.textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          '${tasks.length} generated ${tasks.length == 1 ? 'task' : 'tasks'}',
                          style: theme.textTheme.titleMedium,
                        ),
                      ],
                    ),
                  );
                }
                final task = tasks[index - 1];
                return Padding(
                  key: ValueKey('generated-task-${task.position}'),
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _PreviewCard(task: task, number: index),
                );
              },
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
                        onPressed: saving ? null : () => _cancel(context),
                        child: const Text('Cancel'),
                      );
                      final confirm = FilledButton(
                        key: const Key('confirm-generated-tasks-button'),
                        onPressed: saving || tasks.isEmpty
                            ? null
                            : () => _confirm(context),
                        child: Text(
                          saving ? 'Creating project…' : 'Confirm & Create',
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
}

class _PreviewCard extends StatelessWidget {
  const _PreviewCard({required this.task, required this.number});

  final GeneratedTaskDraft task;
  final int number;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final priority = TaskPriority.fromValue(task.priority);
    final color = AppColors.priority(priority);
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
                    style: theme.textTheme.labelLarge,
                  ),
                ),
                Chip(
                  label: Text(priority.label),
                  backgroundColor: color.withValues(alpha: .10),
                  labelStyle: TextStyle(color: color),
                ),
              ],
            ),
            Text(task.title, style: theme.textTheme.titleMedium),
            if (task.description.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(task.description),
            ],
            const SizedBox(height: 12),
            Text('Deadline: ${DateFormatter.short(task.deadline)}'),
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
                      Expanded(child: Text(item)),
                    ],
                  ),
                ),
          ],
        ),
      ),
    );
  }
}
