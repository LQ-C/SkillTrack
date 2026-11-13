import 'package:skilltrack/features/authentication/viewmodels/auth_view_model.dart';
import 'package:flutter/material.dart';
import 'package:skilltrack/features/authentication/services/account_service.dart';
import 'package:skilltrack/core/utils/validation.dart';
import 'package:skilltrack/core/errors/auth_errors.dart';
import 'package:skilltrack/app/widgets/page_shell.dart';
import 'package:skilltrack/app/widgets/notice.dart';

class RecoveryScreen extends StatefulWidget {
  const RecoveryScreen({
    super.key,
    required this.service,
    required this.onDone,
  });
  final AccountService service;
  final VoidCallback onDone;
  @override
  State<RecoveryScreen> createState() => _RecoveryScreenState();
}

class _RecoveryScreenState extends State<RecoveryScreen> {
  final form = GlobalKey<FormState>();
  final password = TextEditingController(), confirm = TextEditingController();
  late final viewModel = AuthViewModel(widget.service);
  bool busy = false;
  String? error;
  @override
  void dispose() {
    viewModel.dispose();
    password.dispose();
    confirm.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PageShell(
    title: 'A fresh start.',
    subtitle: 'Choose a new password for your account.',
    children: [
      if (error != null) Notice(error!, error: true),
      Form(
        key: form,
        child: Column(
          children: [
            TextFormField(
              controller: password,
              enabled: !busy,
              obscureText: true,
              validator: validatePassword,
              decoration: const InputDecoration(labelText: 'New password'),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: confirm,
              enabled: !busy,
              obscureText: true,
              validator: (v) =>
                  v != password.text ? 'Passwords do not match.' : null,
              decoration: const InputDecoration(labelText: 'Confirm password'),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: busy
                  ? null
                  : () async {
                      if (!form.currentState!.validate()) return;
                      setState(() {
                        busy = true;
                        error = null;
                      });
                      try {
                        await viewModel.recoverPassword(password.text);
                        if (mounted) widget.onDone();
                      } catch (e) {
                        if (mounted) setState(() => error = friendlyError(e));
                      } finally {
                        if (mounted) setState(() => busy = false);
                      }
                    },
              child: Text(busy ? 'Updating…' : 'Update password and sign in'),
            ),
            TextButton(
              onPressed: busy
                  ? null
                  : () async {
                      await viewModel.repository.signOut();
                      if (mounted) widget.onDone();
                    },
              child: const Text('Return to sign in'),
            ),
          ],
        ),
      ),
    ],
  );
}
