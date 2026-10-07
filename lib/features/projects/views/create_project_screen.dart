import 'package:flutter/material.dart';

import '../../../app/router/app_router.dart';
import '../models/learning_project.dart';
import '../repositories/project_repository.dart';
import '../viewmodels/create_project_view_model.dart';

class CreateProjectScreen extends StatefulWidget {
  const CreateProjectScreen({
    super.key,
    required this.repository,
    this.project,
  });
  final ProjectRepository repository;
  final LearningProject? project;

  @override
  State<CreateProjectScreen> createState() => _CreateProjectScreenState();
}

class _CreateProjectScreenState extends State<CreateProjectScreen> {
  late final CreateProjectViewModel _model;
  late final TextEditingController _name, _description;
  DateTime? _startDate, _endDate;
  String _status = 'active';

  @override
  void initState() {
    super.initState();
    final project = widget.project;
    _model = CreateProjectViewModel(widget.repository, original: project);
    _name = TextEditingController(text: project?.name);
    _description = TextEditingController(text: project?.description);
    _startDate = project?.startDate;
    _endDate = project?.endDate;
    _status = project?.status ?? 'active';
  }

  @override
  void dispose() {
    _model.dispose();
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  String _dateText(DateTime? date) => date == null
      ? 'Select date'
      : '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';

  Future<void> _pickDate(bool start) async {
    final selected = await showDatePicker(
      context: context,
      initialDate: (start ? _startDate : _endDate) ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (selected != null && mounted) {
      setState(() {
        if (start) {
          _startDate = selected;
        } else {
          _endDate = selected;
        }
      });
    }
  }

  Widget _dateField(String label, DateTime? value, bool start) => Padding(
    padding: const EdgeInsets.only(top: 16),
    child: Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () => _pickDate(start),
            icon: const Icon(Icons.calendar_today_outlined),
            label: Text('$label: ${_dateText(value)}'),
          ),
        ),
        if (value != null)
          IconButton(
            tooltip: 'Clear $label',
            onPressed: () => setState(() {
              if (start) {
                _startDate = null;
              } else {
                _endDate = null;
              }
            }),
            icon: const Icon(Icons.close),
          ),
      ],
    ),
  );

  Future<void> _submit() async {
    final result = await _model.submit(
      name: _name.text,
      description: _description.text,
      startDate: _startDate,
      endDate: _endDate,
      status: _status,
    );
    if (result != null && mounted) AppRouter.back(context, result);
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.project != null;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Back',
          onPressed: () => AppRouter.back(context),
          icon: const Icon(Icons.arrow_back),
        ),
      ),
      body: SafeArea(
        top: false,
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          children: [
            Text(
              editing ? 'Edit Project' : 'Create Project',
              style: theme.textTheme.headlineLarge?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              editing
                  ? 'Update your project details.'
                  : 'Organize your learning tasks in one place.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 28),
            ListenableBuilder(
              listenable: _model,
              builder: (context, child) => TextField(
                key: const Key('project-name-field'),
                controller: _name,
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
            TextField(
              key: const Key('project-description-field'),
              controller: _description,
              minLines: 3,
              maxLines: 5,
              decoration: const InputDecoration(
                labelText: 'Description',
                hintText: 'What do you want to accomplish?',
              ),
            ),
            _dateField('Start Date', _startDate, true),
            _dateField('End Date', _endDate, false),
            ListenableBuilder(
              listenable: _model,
              builder: (context, child) => _model.dateError == null
                  ? const SizedBox.shrink()
                  : Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        _model.dateError!,
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    ),
            ),
            if (editing) ...[
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: _status,
                decoration: const InputDecoration(labelText: 'Status'),
                items: const [
                  DropdownMenuItem(value: 'active', child: Text('Active')),
                  DropdownMenuItem(
                    value: 'completed',
                    child: Text('Completed'),
                  ),
                  DropdownMenuItem(value: 'archived', child: Text('Archived')),
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
                        style: TextStyle(color: theme.colorScheme.error),
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
          child: ListenableBuilder(
            listenable: _model,
            builder: (context, child) => SizedBox(
              height: 56,
              child: FilledButton(
                key: const Key('save-project-button'),
                onPressed: _model.isSaving ? null : _submit,
                child: Text(
                  _model.isSaving
                      ? editing
                            ? 'Saving…'
                            : 'Creating…'
                      : editing
                      ? 'Save Changes'
                      : 'Create Project',
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
