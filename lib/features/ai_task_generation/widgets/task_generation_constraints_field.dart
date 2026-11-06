import 'package:flutter/material.dart';

import '../../../app/router/app_router.dart';
import '../../../core/constants/app_constants.dart';

class TaskGenerationConstraintsField extends StatelessWidget {
  const TaskGenerationConstraintsField({
    super.key,
    required this.controller,
    this.readOnly = false,
  });

  final TextEditingController controller;
  final bool readOnly;

  @override
  Widget build(BuildContext context) => TextField(
    key: const Key('task-generation-constraints-field'),
    controller: controller,
    readOnly: readOnly,
    minLines: 2,
    maxLines: 4,
    maxLength: AppLimits.maxTaskGenerationConstraintsLength,
    decoration: const InputDecoration(
      labelText: 'Task generation constraints (optional)',
      hintText: 'Example: Maximum 8 tasks, Flutter only, and include testing.',
      helperText: 'Add requirements the generated plan should follow.',
      helperMaxLines: 2,
    ),
  );
}

class TaskGenerationConstraintsDialog extends StatefulWidget {
  const TaskGenerationConstraintsDialog({
    super.key,
    this.initialConstraints = '',
  });

  final String initialConstraints;

  @override
  State<TaskGenerationConstraintsDialog> createState() =>
      _TaskGenerationConstraintsDialogState();
}

class _TaskGenerationConstraintsDialogState
    extends State<TaskGenerationConstraintsDialog> {
  late final TextEditingController _controller;
  bool _submitted = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialConstraints);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _generate() {
    if (_submitted) return;
    setState(() => _submitted = true);
    AppRouter.back(context, _controller.text);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Generate More Tasks'),
    content: SizedBox(
      width: 480,
      child: SingleChildScrollView(
        child: TaskGenerationConstraintsField(
          controller: _controller,
          readOnly: _submitted,
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _submitted ? null : () => AppRouter.back(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const Key('generate-additional-tasks-button'),
        onPressed: _submitted ? null : _generate,
        child: const Text('Generate'),
      ),
    ],
  );
}
