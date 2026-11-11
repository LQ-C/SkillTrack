import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/router/app_router.dart';
import '../../../core/errors/app_exception.dart';
import '../models/kanban_task.dart';
import '../models/task_attachment.dart';
import '../services/attachment_reader.dart';
import '../viewmodels/kanban_view_model.dart';

class AttachmentSection extends StatefulWidget {
  const AttachmentSection({
    super.key,
    required this.task,
    required this.viewModel,
  });
  final KanbanTask task;
  final KanbanViewModel viewModel;

  @override
  State<AttachmentSection> createState() => _AttachmentSectionState();
}

class _AttachmentSectionState extends State<AttachmentSection> {
  bool _isPickingAttachment = false;
  bool _isShowingDeleteDialog = false;
  String? _openingAttachmentId;
  KanbanViewModel get viewModel => widget.viewModel;
  KanbanTask get task => widget.task;

  Future<void> _upload(BuildContext context) async {
    if (_isPickingAttachment || viewModel.isSaving) return;
    setState(() => _isPickingAttachment = true);
    try {
      try {
        final selection = await FilePicker.pickFiles(
          withData: false,
          withReadStream: true,
        );
        final file = selection?.files.singleOrNull;
        if (file == null) return;
        final bytes = await readTaskAttachment(
          file.readStream,
          declaredSize: file.size,
        );
        if (!context.mounted) return;
        await viewModel.uploadAttachment(
          task.id,
          file.name,
          bytes,
          'application/octet-stream',
        );
      } catch (error) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                AppException.messageFor(
                  error,
                  fallback: 'Unable to select this file.',
                ),
              ),
            ),
          );
        }
      }
    } finally {
      if (mounted) setState(() => _isPickingAttachment = false);
    }
  }

  Future<void> _open(BuildContext context, TaskAttachment attachment) async {
    if (_openingAttachmentId != null) return;
    setState(() => _openingAttachmentId = attachment.id);
    try {
      try {
        final url = await viewModel.getAttachmentUrl(attachment);
        if (!context.mounted) return;
        if (!await launchUrl(
          Uri.parse(url),
          mode: LaunchMode.externalApplication,
        )) {
          throw StateError('Could not open attachment');
        }
      } catch (_) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Unable to open this attachment.')),
          );
        }
      }
    } finally {
      if (mounted) setState(() => _openingAttachmentId = null);
    }
  }

  Future<void> _delete(BuildContext context, TaskAttachment attachment) async {
    if (_isShowingDeleteDialog || viewModel.isSaving) return;
    setState(() => _isShowingDeleteDialog = true);
    try {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Delete attachment?'),
          content: Text('Remove ${attachment.fileName}?'),
          actions: [
            TextButton(
              onPressed: () => AppRouter.back(dialogContext, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => AppRouter.back(dialogContext, true),
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error,
              ),
              child: const Text('Delete'),
            ),
          ],
        ),
      );
      if (confirm == true && context.mounted) {
        await viewModel.deleteAttachment(attachment);
      }
    } finally {
      if (mounted) setState(() => _isShowingDeleteDialog = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: viewModel,
    builder: (context, child) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Attachments', style: Theme.of(context).textTheme.titleMedium),
        ...task.attachments.map(
          (attachment) => ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              Icons.attach_file,
              color: Theme.of(context).colorScheme.primary,
            ),
            title: Text(attachment.fileName),
            subtitle: Text(
              '${attachment.mimeType ?? 'File'} · ${attachment.fileSizeBytes ?? 0} bytes',
            ),
            onTap: _openingAttachmentId != null
                ? null
                : () => _open(context, attachment),
            trailing: IconButton(
              tooltip: 'Delete attachment',
              color: Theme.of(context).colorScheme.error,
              icon: const Icon(Icons.delete_outline),
              onPressed: _isShowingDeleteDialog || viewModel.isSaving
                  ? null
                  : () => _delete(context, attachment),
            ),
          ),
        ),
        OutlinedButton.icon(
          onPressed: viewModel.isSaving || _isPickingAttachment
              ? null
              : () => _upload(context),
          icon: const Icon(Icons.upload_file),
          label: const Text('Upload attachment'),
        ),
      ],
    ),
  );
}
