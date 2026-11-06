import 'package:flutter/material.dart';

import '../../../core/utils/date_formatter.dart';
import '../../ai_task_generation/widgets/task_generation_constraints_field.dart';

import '../../../app/widgets/app_content.dart';

import '../../../app/router/app_router.dart';
import '../../kanban/repositories/kanban_repository.dart';
import '../models/learning_project.dart';
import '../repositories/project_repository.dart';
import '../../ai_task_generation/repositories/ai_task_generation_repository.dart';
import '../viewmodels/create_project_view_model.dart';

class CreateProjectScreen extends StatefulWidget {
  const CreateProjectScreen({
    super.key,
    required this.repository,
    this.generationRepository,
    this.taskRepository,
    this.project,
  });
  final ProjectRepository repository;
  final TaskGenerationRepository? generationRepository;
  final KanbanRepository? taskRepository;
  final LearningProject? project;

  @override
  State<CreateProjectScreen> createState() => _CreateProjectScreenState();
}

class _CreateProjectScreenState extends State<CreateProjectScreen> {
  late final CreateProjectViewModel _model;
  late final TextEditingController _name, _description, _constraints;
  String _status = 'active';
  bool _previewOpen = false;
  bool _isPickingDate = false;
  bool _isLeaving = false;

  @override
  void initState() {
    super.initState();
    final project = widget.project;
    _model = CreateProjectViewModel(
      widget.repository,
      original: project,
      generationRepository: widget.generationRepository,
      taskRepository: widget.taskRepository,
    );
    _name = TextEditingController(text: project?.name);
    _description = TextEditingController(text: project?.description);
    _constraints = TextEditingController(text: project?.constraints);
    _status = project?.status ?? 'active';
  }

  @override
  void dispose() {
    _model.dispose();
    _name.dispose();
    _description.dispose();
    _constraints.dispose();
    super.dispose();
  }

  Future<void> _pickDate(bool start) async {
    if (_isPickingDate) return;
    setState(() => _isPickingDate = true);
    try {
      if (_model.isSaving || _model.isGeneratingTasks) return;
      final today = DateFormatter.today();
      final startDate = _model.startDate;
      final firstDate = widget.project != null
          ? DateTime(2000)
          : !start && startDate != null && startDate.isAfter(today)
          ? startDate
          : today;
      final limit = DateTime(2100);
      final lastDate = limit.isBefore(firstDate) ? firstDate : limit;
      final value = (start ? _model.startDate : _model.endDate) ?? firstDate;
      final initialDate = value.isBefore(firstDate)
          ? firstDate
          : value.isAfter(lastDate)
          ? lastDate
          : value;
      final selected = await showDatePicker(
        context: context,
        initialDate: initialDate,
        firstDate: firstDate,
        lastDate: lastDate,
      );
      if (selected != null && mounted) {
        if (start) {
          _model.setStartDate(selected);
        } else {
          _model.setEndDate(selected);
        }
      }
    } finally {
      if (mounted) setState(() => _isPickingDate = false);
    }
  }

  Widget _dateField(String label, bool start) => ListenableBuilder(
    listenable: _model,
    builder: (context, child) {
      final theme = Theme.of(context);
      final colors = theme.colorScheme;
      final value = start ? _model.startDate : _model.endDate;
      final error = start ? _model.startDateError : _model.endDateError;
      final enabled =
          !_isPickingDate && !_model.isSaving && !_model.isGeneratingTasks;
      final dates = MaterialLocalizations.of(context);
      final text = value == null
          ? 'Select date'
          : '${dates.formatMediumDate(value)}, ${dates.formatYear(value)}';
      final shape = RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: error == null ? colors.outlineVariant : colors.error,
        ),
      );
      return Padding(
        padding: const EdgeInsets.only(top: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Material(
              color: colors.surface,
              shape: shape,
              clipBehavior: Clip.antiAlias,
              child: Semantics(
                button: true,
                enabled: enabled,
                label: 'Select $label',
                child: InkWell(
                  key: Key(
                    start
                        ? 'project-start-date-field'
                        : 'project-end-date-field',
                  ),
                  onTap: enabled ? () => _pickDate(start) : null,
                  customBorder: shape,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: colors.primaryContainer,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            Icons.calendar_today_outlined,
                            size: 20,
                            color: enabled
                                ? colors.onPrimaryContainer
                                : theme.disabledColor,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(label, style: theme.textTheme.labelSmall),
                              const SizedBox(height: 2),
                              Text(
                                text,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  color: enabled
                                      ? colors.onSurface
                                      : theme.disabledColor,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (value != null)
                          IconButton(
                            tooltip: 'Clear $label',
                            color: colors.onSurfaceVariant,
                            onPressed: enabled
                                ? () => start
                                      ? _model.setStartDate(null)
                                      : _model.setEndDate(null)
                                : null,
                            icon: const Icon(Icons.close),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8, left: 12),
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    error,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.error,
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );

  Future<void> _submit() async {
    if (_isLeaving || _model.isSaving || _model.isGeneratingTasks) return;
    final result = await _model.submit(
      name: _name.text,
      description: _description.text,
      status: _status,
      constraints: _constraints.text,
    );
    if (result != null && mounted) {
      setState(() => _isLeaving = true);
      AppRouter.back(context, result);
    }
  }

  Future<void> _generateTasks() async {
    if (_isLeaving ||
        _previewOpen ||
        _model.isGeneratingTasks ||
        _model.isSaving) {
      return;
    }
    _previewOpen = true;
    FocusScope.of(context).unfocus();
    try {
      final drafts = await _model.generateTaskPreview(
        name: _name.text,
        description: _description.text,
        constraints: _constraints.text,
      );
      if (!mounted || drafts == null) return;
      final result = await AppRouter.generatedTaskPreview(context, _model);
      if (mounted && result != null) {
        setState(() => _isLeaving = true);
        AppRouter.back(context, result);
      }
    } finally {
      _previewOpen = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.project != null;
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: _model,
      builder: (context, child) => PopScope(
        canPop: !_model.isGeneratingTasks,
        child: Scaffold(
          appBar: AppBar(
            leading: IconButton(
              tooltip: 'Back',
              onPressed: _model.isGeneratingTasks
                  ? null
                  : () => AppRouter.back(context),
              icon: const Icon(Icons.arrow_back),
            ),
          ),
          body: Stack(
            children: [
              SafeArea(
                top: false,
                bottom: !editing,
                child: AppContent(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                    children: [
                      Text(
                        editing ? 'Edit Project' : 'Create Project',
                        style: theme.textTheme.headlineLarge,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        editing
                            ? 'Update your project details.'
                            : 'Organize your learning tasks in one place.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 28),
                      ListenableBuilder(
                        listenable: _model,
                        builder: (context, child) => TextField(
                          key: const Key('project-name-field'),
                          controller: _name,
                          readOnly: _model.isGeneratingTasks,
                          maxLength: 150,
                          textCapitalization: TextCapitalization.words,
                          decoration: InputDecoration(
                            labelText: 'Project Name *',
                            hintText: 'Enter project name',
                            errorText: _model.nameError,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      ListenableBuilder(
                        listenable: _model,
                        builder: (context, child) => TextField(
                          key: const Key('project-description-field'),
                          controller: _description,
                          readOnly: _model.isGeneratingTasks,
                          minLines: 3,
                          maxLines: 5,
                          decoration: InputDecoration(
                            labelText: 'Description',
                            hintText: 'What do you want to accomplish?',
                            errorText: _model.descriptionError,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TaskGenerationConstraintsField(
                        controller: _constraints,
                        readOnly: _model.isGeneratingTasks || _model.isSaving,
                      ),
                      _dateField('Start date', true),
                      _dateField('End date', false),
                      if (editing) ...[
                        const SizedBox(height: 16),
                        DropdownButtonFormField<String>(
                          initialValue: _status,
                          decoration: const InputDecoration(
                            labelText: 'Status',
                          ),
                          items: const [
                            DropdownMenuItem(
                              value: 'active',
                              child: Text('Active'),
                            ),
                            DropdownMenuItem(
                              value: 'completed',
                              child: Text('Completed'),
                            ),
                            DropdownMenuItem(
                              value: 'archived',
                              child: Text('Archived'),
                            ),
                          ],
                          onChanged: (value) =>
                              setState(() => _status = value ?? _status),
                        ),
                      ],
                      ListenableBuilder(
                        listenable: _model,
                        builder: (context, child) => _model.errorMessage == null
                            ? const SizedBox.shrink()
                            : Padding(
                                padding: const EdgeInsets.only(top: 16),
                                child: Text(
                                  _model.errorMessage!,
                                  style: TextStyle(
                                    color: theme.colorScheme.error,
                                  ),
                                ),
                              ),
                      ),
                      if (!editing) ...[
                        const SizedBox(height: 24),
                        ListenableBuilder(
                          listenable: _model,
                          builder: (context, child) => Column(
                            children: [
                              SizedBox(
                                height: 56,
                                width: double.infinity,
                                child: FilledButton(
                                  key: const Key('save-project-button'),
                                  onPressed:
                                      _isLeaving ||
                                          _model.isSaving ||
                                          _model.isGeneratingTasks ||
                                          _model.pendingProject != null
                                      ? null
                                      : _submit,
                                  child: Text(
                                    _model.isSaving && !_model.isGeneratingTasks
                                        ? 'Creating…'
                                        : 'Create Empty Project',
                                  ),
                                ),
                              ),
                              const SizedBox(height: 16),
                              Row(
                                children: [
                                  const Expanded(child: Divider()),
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                    ),
                                    child: Text(
                                      'OR',
                                      style: theme.textTheme.labelMedium,
                                    ),
                                  ),
                                  const Expanded(child: Divider()),
                                ],
                              ),
                              const SizedBox(height: 16),
                              SizedBox(
                                height: 56,
                                width: double.infinity,
                                child: OutlinedButton(
                                  key: const Key('generate-tasks-button'),
                                  onPressed:
                                      _model.isSaving ||
                                          _model.isGeneratingTasks
                                      ? null
                                      : _generateTasks,
                                  child: Text(
                                    _model.pendingProject != null
                                        ? 'Retry Saving Tasks'
                                        : 'Generate Tasks',
                                  ),
                                ),
                              ),
                              if (_model.pendingProject != null) ...[
                                const SizedBox(height: 12),
                                TextButton(
                                  key: const Key('open-empty-project-button'),
                                  onPressed: _model.isSaving
                                      ? null
                                      : () => AppRouter.back(
                                          context,
                                          _model.pendingProject,
                                        ),
                                  child: const Text('Open empty project'),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              if (_model.isGeneratingTasks) ...[
                const Positioned.fill(
                  child: ModalBarrier(
                    dismissible: false,
                    color: Colors.black54,
                  ),
                ),
                Center(
                  child: Card(
                    margin: const EdgeInsets.all(28),
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const CircularProgressIndicator(),
                          const SizedBox(height: 20),
                          Text(
                            'Generating your task plan',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Creating tasks and checklists…',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
          bottomNavigationBar: editing
              ? SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                    child: ListenableBuilder(
                      listenable: _model,
                      builder: (context, child) => SizedBox(
                        height: 56,
                        child: FilledButton(
                          key: const Key('save-project-button'),
                          onPressed: _isLeaving || _model.isSaving
                              ? null
                              : _submit,
                          child: Text(
                            _model.isSaving ? 'Saving…' : 'Save Changes',
                          ),
                        ),
                      ),
                    ),
                  ),
                )
              : null,
        ),
      ),
    );
  }
}
