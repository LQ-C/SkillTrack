import 'package:skilltrack/features/authentication/viewmodels/auth_view_model.dart';
import 'package:flutter/material.dart';
import 'package:skilltrack/features/authentication/services/account_service.dart';
import 'package:skilltrack/core/utils/validation.dart';
import 'package:skilltrack/app/widgets/page_shell.dart';
import 'package:skilltrack/app/widgets/notice.dart';
import 'package:skilltrack/app/widgets/birth_field.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key, required this.service, this.initialMessage});
  final AccountService service;
  final String? initialMessage;
  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final form = GlobalKey<FormState>();
  final email = TextEditingController(), password = TextEditingController();
  final name = TextEditingController(),
      birth = TextEditingController(),
      confirm = TextEditingController();
  bool register = false, hidden = true;
  late final viewModel = AuthViewModel(widget.service);
  bool get busy => viewModel.busy;
  bool get error => viewModel.error;
  set error(bool value) => viewModel.error = value;
  String? get message => viewModel.message;
  set message(String? value) => viewModel.message = value;
  void refresh() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    viewModel.addListener(refresh);
  }

  String role = 'student';
  @override
  void dispose() {
    viewModel.dispose();
    for (final c in [email, password, name, birth, confirm]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> perform(Future<String?> Function() operation) =>
      viewModel.perform(operation);

  Future<void> submit() async {
    if (!form.currentState!.validate()) return;
    await perform(() async {
      if (register) {
        final result = await viewModel.register(
          email: email.text,
          password: password.text,
          name: name.text,
          birthDate: birth.text,
          role: role,
        );
        if (result.verificationRequired) {
          if (!mounted) return null;
          password.clear();
          confirm.clear();
          return 'Check your inbox for a verification link, then return here to sign in. If you already have an account, sign in or reset your password.';
        }
      } else {
        await viewModel.signIn(email.text, password.text);
      }
      return null;
    });
  }

  void emailAction(bool reset) {
    if (validateEmail(email.text) != null) {
      setState(() {
        error = true;
        message = 'Enter your email address first.';
      });
      return;
    }
    perform(() async {
      await viewModel.sendEmail(email.text, reset: reset);
      return 'If your account is eligible, an email has been sent. Check your inbox and spam folder.';
    });
  }

  @override
  Widget build(BuildContext context) => PageShell(
    title: register ? 'Make room for growth.' : 'Welcome back.',
    subtitle: register
        ? 'Create your account and start your learning journey.'
        : 'Your skills. Your people. Your next step.',
    children: [
      SegmentedButton<bool>(
        segments: const [
          ButtonSegment(value: false, label: Text('Sign in')),
          ButtonSegment(value: true, label: Text('Create account')),
        ],
        selected: {register},
        onSelectionChanged: busy
            ? null
            : (value) {
                setState(() {
                  register = value.first;
                  message = null;
                  password.clear();
                  confirm.clear();
                  form.currentState?.reset();
                });
              },
      ),
      const SizedBox(height: 24),
      if ((message ?? widget.initialMessage) != null)
        Notice(
          (message ?? widget.initialMessage)!,
          error: error || widget.initialMessage != null,
        ),
      Form(
        key: form,
        child: AutofillGroup(
          child: Column(
            children: [
              if (register) ...[
                TextFormField(
                  controller: name,
                  enabled: !busy,
                  decoration: const InputDecoration(
                    labelText: 'Full name',
                    prefixIcon: Icon(Icons.person_outline),
                  ),
                  validator: validateName,
                  autofillHints: const [AutofillHints.name],
                ),
                const SizedBox(height: 16),
                BirthField(controller: birth, enabled: !busy),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  initialValue: role,
                  decoration: const InputDecoration(
                    labelText: 'I want to join as',
                  ),
                  items: const [
                    DropdownMenuItem(value: 'student', child: Text('Student')),
                    DropdownMenuItem(value: 'mentor', child: Text('Mentor')),
                  ],
                  onChanged: busy ? null : (v) => setState(() => role = v!),
                ),
                const SizedBox(height: 16),
              ],
              TextFormField(
                controller: email,
                enabled: !busy,
                keyboardType: TextInputType.emailAddress,
                autocorrect: false,
                autofillHints: const [AutofillHints.email],
                validator: validateEmail,
                decoration: const InputDecoration(
                  labelText: 'Email address',
                  prefixIcon: Icon(Icons.alternate_email),
                ),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: password,
                enabled: !busy,
                obscureText: hidden,
                autocorrect: false,
                enableSuggestions: false,
                autofillHints: [
                  register ? AutofillHints.newPassword : AutofillHints.password,
                ],
                validator: register
                    ? validatePassword
                    : (v) => (v ?? '').isEmpty ? 'Enter your password.' : null,
                decoration: InputDecoration(
                  labelText: 'Password',
                  prefixIcon: const Icon(Icons.lock_outline),
                  suffixIcon: IconButton(
                    tooltip: hidden ? 'Show password' : 'Hide password',
                    onPressed: () => setState(() => hidden = !hidden),
                    icon: Icon(
                      hidden
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                    ),
                  ),
                ),
              ),
              if (register) ...[
                const SizedBox(height: 8),
                const Text(
                  'At least 8 characters, with uppercase, lowercase, a number and a symbol.',
                  style: TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: confirm,
                  enabled: !busy,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Confirm password',
                  ),
                  validator: (v) =>
                      v != password.text ? 'Passwords do not match.' : null,
                ),
              ],
              const SizedBox(height: 24),
              FilledButton(
                onPressed: busy ? null : submit,
                child: busy
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(register ? 'Create my account' : 'Sign in'),
              ),
            ],
          ),
        ),
      ),
      if (!register) ...[
        const SizedBox(height: 8),
        TextButton(
          onPressed: busy ? null : () => emailAction(true),
          child: const Text('Forgot password?'),
        ),
        TextButton(
          onPressed: busy ? null : () => emailAction(false),
          child: const Text('Resend verification email'),
        ),
      ],
      const SizedBox(height: 20),
      const Text(
        'Build skills at your own pace.',
        textAlign: TextAlign.center,
        style: TextStyle(color: Color(0xFF686371)),
      ),
    ],
  );
}
