import 'package:flutter/material.dart';
import 'package:skilltrack/app/app_colors.dart';
import 'package:skilltrack/core/utils/validation.dart';

class SecurityDialog extends StatefulWidget {
  const SecurityDialog({super.key, required this.delete});
  final bool delete;
  @override
  State<SecurityDialog> createState() => _SecurityDialogState();
}

class _SecurityDialogState extends State<SecurityDialog> {
  final current = TextEditingController(),
      next = TextEditingController(),
      confirm = TextEditingController();
  final form = GlobalKey<FormState>();
  @override
  void dispose() {
    current.dispose();
    next.dispose();
    confirm.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.delete ? 'Delete your account?' : 'Change password'),
    content: SingleChildScrollView(
      child: Form(
        key: form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.delete
                  ? 'This permanently deletes your account and profile. Enter your current password to confirm.'
                  : 'Confirm your current password, then choose a new one.',
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: current,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Current password'),
              validator: (v) =>
                  (v ?? '').isEmpty ? 'Enter your current password.' : null,
            ),
            if (!widget.delete) ...[
              const SizedBox(height: 16),
              TextFormField(
                controller: next,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'New password'),
                validator: validatePassword,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: confirm,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Confirm new password',
                ),
                validator: (v) =>
                    v != next.text ? 'Passwords do not match.' : null,
              ),
            ],
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
            Navigator.pop(context, [current.text, next.text]);
          }
        },
        child: Text(
          widget.delete ? 'Delete permanently' : 'Update password',
          style: TextStyle(color: widget.delete ? Colors.red.shade800 : green),
        ),
      ),
    ],
  );
}
