import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/router/app_router.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/errors/app_exception.dart';
import '../models/kanban_task.dart';
import '../models/task_attachment.dart';
import '../viewmodels/kanban_view_model.dart';

class AttachmentSection extends StatelessWidget {
  const AttachmentSection({
    super.key,
    required this.task,
    required this.viewModel,
  });
  final KanbanTask task;
  final KanbanViewModel viewModel;

  Future<void> _upload(BuildContext context) async {
    try {
      final selection = await FilePicker.pickFiles(
        withData: false,
        withReadStream: true,
      );
      final file = selection?.files.singleOrNull;
      if (file == null) return;
      if (file.size > AppLimits.maxAttachmentBytes) {
        throw const AppException(AppErrorMessages.attachmentTooLarge);
      }
      final stream = file.readStream;
      if (stream == null) throw StateError('File data unavailable');
      final buffer = BytesBuilder(copy: false);
      await for (final chunk in stream) {
        if (buffer.length + chunk.length > AppLimits.maxAttachmentBytes) {
          throw const AppException(AppErrorMessages.attachmentTooLarge);
        }
        buffer.add(chunk);
      }
      if (!context.mounted) return;
      await viewModel.uploadAttachment(
        task.id,
        file.name,
        buffer.takeBytes(),
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
  }

  Future<void> _open(BuildContext context, TaskAttachment attachment) async {
    try {
      final url = await viewModel.getAttachmentUrl(attachment);
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
  }

  Future<void> _delete(BuildContext context, TaskAttachment attachment) async {
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
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm == true) await viewModel.deleteAttachment(attachment);
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('Attachments', style: Theme.of(context).textTheme.titleMedium),
      ...task.attachments.map(
        (attachment) => ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.attach_file),
          title: Text(attachment.fileName),
          subtitle: Text(
            '${attachment.mimeType ?? 'File'} · ${attachment.fileSizeBytes ?? 0} bytes',
          ),
          onTap: () => _open(context, attachment),
          trailing: IconButton(
            tooltip: 'Delete attachment',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _delete(context, attachment),
          ),
        ),
      ),
      OutlinedButton.icon(
        onPressed: viewModel.isSaving ? null : () => _upload(context),
        icon: const Icon(Icons.upload_file),
        label: const Text('Upload attachment'),
      ),
    ],
  );
}
