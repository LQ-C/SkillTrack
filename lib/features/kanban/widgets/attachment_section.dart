import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

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
      final selection = await FilePicker.pickFiles(withData: true);
      final file = selection?.files.singleOrNull;
      if (file == null) return;
      if (file.bytes == null) throw StateError('File data unavailable');
      await viewModel.uploadAttachment(task.id, file.name, file.bytes!, null);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Unable to select this file.')),
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
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
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
