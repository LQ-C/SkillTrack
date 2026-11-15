import '../../../app/widgets/category_dropdown.dart';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';

import '../viewmodels/resource_editor_view_model.dart';
import 'package:flutter/material.dart';
import 'package:skilltrack/features/educational_content/models/learning_resource.dart';
import 'package:skilltrack/features/educational_content/repositories/content_repository.dart';
import 'package:skilltrack/features/educational_content/widgets/content_notice.dart';
import 'package:skilltrack/core/constants/content_options.dart';
import 'package:skilltrack/features/educational_content/utils/content_validation.dart';

class ResourceEditor extends StatefulWidget {
  const ResourceEditor({
    super.key,
    required this.repository,
    this.resource,
    required this.canPublish,
  });
  final ContentRepository repository;
  final LearningResource? resource;
  final bool canPublish;
  @override
  State<ResourceEditor> createState() => _ResourceEditorState();
}

class _ResourceEditorState extends State<ResourceEditor> {
  final form = GlobalKey<FormState>();
  final title = TextEditingController(), summary = TextEditingController();
  ({String name, Uint8List bytes})? attachment;
  bool picking = false;
  String? pickerError;
  String category = contentCategories.first,
      level = contentLevels.first,
      kind = contentKinds.first,
      status = 'draft';
  bool dirty = false;
  late final viewModel = ResourceEditorViewModel(widget.repository);
  bool get busy => viewModel.busy;
  String? get error => viewModel.error;
  void refresh() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    viewModel.addListener(refresh);
    final r = widget.resource;
    if (r != null) {
      title.text = r.title;
      summary.text = r.summary;
      category = r.category;
      level = r.level;
      kind = contentKinds.contains(r.kind) ? r.kind : 'Reading';
      status = !widget.canPublish && r.status == 'published'
          ? 'draft'
          : r.status;
    }
  }

  @override
  void dispose() {
    viewModel.dispose();
    for (final c in [title, summary]) {
      c.dispose();
    }
    super.dispose();
  }

  bool get video => kind == 'Video';
  bool get sameResourceType => widget.resource?.kind == kind;
  int get maxFileMb => video ? 50 : 10;

  Future<void> pickResourceFile() async {
    setState(() {
      picking = true;
      pickerError = null;
    });
    try {
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: video ? ['mp4'] : ['pdf', 'png', 'jpg', 'jpeg'],
      );
      if (file == null || !mounted) return;
      final length = await file.length();
      if (length == null || length < 1 || length > maxFileMb * 1024 * 1024) {
        setState(
          () => pickerError = 'Choose a non-empty file up to $maxFileMb MB.',
        );
        return;
      }
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      setState(() {
        attachment = (name: file.name, bytes: bytes);
        dirty = true;
      });
    } catch (_) {
      if (mounted) setState(() => pickerError = 'Could not read the file.');
    } finally {
      if (mounted) setState(() => picking = false);
    }
  }

  Future<void> save() async {
    if (picking) return;
    if (!form.currentState!.validate()) return;
    final existing = widget.resource;
    final saved = await viewModel.save(
      {
        'title': title.text.trim(),
        'summary': summary.text.trim(),
        'external_url': sameResourceType ? (existing?.link ?? '') : '',
        if (!sameResourceType && existing?.attachmentPath != null)
          'attachment_path': null,
        'category': category,
        'difficulty': level,
        'kind': kind,
        'tags': widget.resource?.tags ?? <String>[],
        'status': status,
      },
      id: existing?.id,
      attachment: attachment,
    );
    if (saved && mounted) {
      setState(() => dirty = false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.pop(context, true);
      });
    }
  }

  Future<void> discard() async {
    if (busy) return;
    final leave = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard unsaved changes?'),
        content: const Text('Your changes have not been saved.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep editing'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (leave == true && mounted) {
      setState(() => dirty = false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.pop(context);
      });
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !dirty && !busy,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop && !busy) discard();
    },
    child: Scaffold(
      appBar: AppBar(
        title: Text(
          widget.resource == null ? 'Add learning resource' : 'Edit resource',
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Form(
            key: form,
            onChanged: () {
              if (!dirty) setState(() => dirty = true);
            },
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Share what you know.',
                    style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'Upload a video or reading file you have permission to share.',
                  ),
                  const SizedBox(height: 22),
                  if (error != null) ContentNotice(error!, error: true),
                  TextFormField(
                    controller: title,
                    enabled: !busy,
                    maxLength: 120,
                    decoration: const InputDecoration(
                      labelText: 'Resource title',
                    ),
                    validator: (v) => contentText(v, 'Title', 3, 120),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: summary,
                    enabled: !busy,
                    minLines: 2,
                    maxLines: 4,
                    maxLength: 500,
                    decoration: const InputDecoration(
                      labelText: 'Short description',
                    ),
                    validator: (v) => contentText(v, 'Description', 20, 500),
                  ),
                  const SizedBox(height: 12),
                  dropdown('Resource type', kind, contentKinds, (v) {
                    if (kind == v) return;
                    kind = v;
                    attachment = null;
                    pickerError = null;
                  }),
                  const SizedBox(height: 16),
                  dropdown('Skill category', category, [
                    if (!contentCategories.contains(category)) category,
                    ...contentCategories,
                  ], (v) => category = v),
                  const SizedBox(height: 16),
                  dropdown(
                    'Difficulty',
                    level,
                    contentLevels,
                    (v) => level = v,
                  ),
                  const SizedBox(height: 16),
                  FormField<bool>(
                    key: ValueKey(kind),
                    validator: (_) {
                      final existing = widget.resource;
                      if (attachment != null ||
                          (sameResourceType &&
                              (existing!.attachmentPath != null ||
                                  existing.link.isNotEmpty))) {
                        return null;
                      }
                      return video
                          ? 'Choose an MP4 video.'
                          : 'Choose a reading file.';
                    },
                    builder: (field) => Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        OutlinedButton.icon(
                          onPressed: busy || picking
                              ? null
                              : () async {
                                  await pickResourceFile();
                                  if (field.mounted && attachment != null) {
                                    field.validate();
                                  }
                                },
                          icon: const Icon(Icons.upload_file),
                          label: Text(
                            attachment?.name ??
                                (video
                                    ? 'Choose MP4 video'
                                    : 'Choose reading file'),
                          ),
                        ),
                        Text(
                          pickerError ??
                              field.errorText ??
                              (video
                                  ? 'MP4 · Up to 50 MB'
                                  : 'PDF, PNG or JPEG · Up to 10 MB'),
                        ),
                        if (sameResourceType && attachment == null)
                          Text(
                            widget.resource!.attachmentPath != null
                                ? 'Current file will be kept.'
                                : 'Current link will be kept.',
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    initialValue: status,
                    decoration: const InputDecoration(labelText: 'Visibility'),
                    items: [
                      const DropdownMenuItem(
                        value: 'draft',
                        child: Text('Draft — only you'),
                      ),
                      if (widget.canPublish)
                        const DropdownMenuItem(
                          value: 'published',
                          child: Text('Published — paid students'),
                        ),
                      const DropdownMenuItem(
                        value: 'archived',
                        child: Text('Archived — only you'),
                      ),
                    ],
                    onChanged: busy || picking
                        ? null
                        : (v) => setState(() {
                            status = v!;
                            dirty = true;
                          }),
                  ),
                  const SizedBox(height: 12),
                  if (!widget.canPublish)
                    const ContentNotice(
                      'Save a draft while your mentor publishing access is being approved.',
                    ),
                  if (widget.resource?.hidden == true)
                    const ContentNotice(
                      'This resource is hidden by moderation. Editing it will not make it visible until an administrator restores it.',
                    ),
                  FilledButton(
                    onPressed: busy ? null : save,
                    child: Text(busy ? 'Saving…' : 'Save resource'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
  Widget dropdown(
    String label,
    String value,
    List<String> options,
    void Function(String) change,
  ) => label == 'Skill category'
      ? categoryDropdown(
          context: context,
          label: label,
          value: value,
          options: options,
          validator: (value) => contentCategories.contains(value)
              ? null
              : 'Choose one of the updated skill categories.',
          onChanged: busy || picking
              ? null
              : (v) => setState(() {
                  change(v!);
                  dirty = true;
                }),
        )
      : DropdownButtonFormField<String>(
          initialValue: value,
          isExpanded: true,
          validator: label == 'Skill category'
              ? (value) => contentCategories.contains(value)
                    ? null
                    : 'Choose one of the updated skill categories.'
              : null,
          decoration: InputDecoration(labelText: label),
          items: options
              .map((v) => DropdownMenuItem(value: v, child: Text(v)))
              .toList(),
          onChanged: busy || picking
              ? null
              : (v) => setState(() {
                  change(v!);
                  dirty = true;
                }),
        );
}
