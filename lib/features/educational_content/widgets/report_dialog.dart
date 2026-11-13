import 'package:flutter/material.dart';
import 'package:skilltrack/features/educational_content/utils/content_validation.dart';

class ReportDialog extends StatefulWidget {
  const ReportDialog({super.key});
  @override
  State<ReportDialog> createState() => _ReportDialogState();
}

class _ReportDialogState extends State<ReportDialog> {
  final form = GlobalKey<FormState>();
  final details = TextEditingController();
  String reason = 'Inaccurate information';
  @override
  void dispose() {
    details.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Report resource'),
    content: SingleChildScrollView(
      child: Form(
        key: form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              initialValue: reason,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Reason'),
              items: [
                'Inaccurate information',
                'Inappropriate content',
                'Copyright concern',
                'Broken link',
                'Spam',
                'Other',
              ].map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(),
              onChanged: (v) => setState(() => reason = v!),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: details,
              maxLines: 4,
              maxLength: 1000,
              decoration: const InputDecoration(
                labelText: 'What should we review?',
              ),
              validator: (v) => contentText(v, 'Report details', 10, 1000),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      TextButton(
        onPressed: () {
          if (form.currentState!.validate()) {
            Navigator.pop(context, (reason: reason, details: details.text));
          }
        },
        child: const Text('Submit report'),
      ),
    ],
  );
}
