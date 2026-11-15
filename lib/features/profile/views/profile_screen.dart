import 'package:skilltrack/features/profile/viewmodels/profile_view_model.dart';
import 'package:flutter/material.dart';
import 'package:skilltrack/features/authentication/services/account_service.dart';
import 'package:skilltrack/core/utils/validation.dart';
import 'package:skilltrack/app/widgets/page_shell.dart';
import 'package:skilltrack/app/widgets/notice.dart';
import 'package:skilltrack/app/app_colors.dart';
import 'package:skilltrack/app/router/app_router.dart';
import 'package:skilltrack/app/widgets/birth_field.dart';
import 'package:skilltrack/features/profile/widgets/security_dialog.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key, required this.service});
  final AccountService service;
  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final form = GlobalKey<FormState>();
  final name = TextEditingController(),
      birth = TextEditingController(),
      bio = TextEditingController();
  String role = 'student';
  bool _openingNotificationSettings = false;
  late final viewModel = ProfileViewModel(widget.service, widget.service);
  String? get message => viewModel.message;
  bool get loading => viewModel.loading;
  bool get busy => viewModel.busy;
  bool get error => viewModel.error;
  bool get loaded => viewModel.loaded;
  void refresh() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    viewModel.addListener(refresh);
    load();
  }

  @override
  void dispose() {
    viewModel.dispose();
    name.dispose();
    birth.dispose();
    bio.dispose();
    super.dispose();
  }

  Future<void> load() async {
    final profile = await viewModel.load();
    if (!mounted || profile == null) return;
    name.text = profile.name;
    birth.text = profile.birthDate;
    bio.text = profile.bio;
    setState(() => role = profile.role);
  }

  Future<void> openNotificationSettings() async {
    if (busy || _openingNotificationSettings) return;
    setState(() => _openingNotificationSettings = true);
    try {
      await AppRouter.notificationPreferences(context);
    } finally {
      if (mounted) setState(() => _openingNotificationSettings = false);
    }
  }

  Future<void> securityDialog({required bool delete}) async {
    final result = await showDialog<List<String>>(
      context: context,
      builder: (context) => SecurityDialog(delete: delete),
    );
    if (result == null || !mounted) return;
    await viewModel.secureAction(delete, result[0], result[1]);
  }

  @override
  Widget build(BuildContext context) => PageShell(
    title: 'A little about you.',
    subtitle: 'Make your profile feel like you.',
    actions: [
      TextButton(
        onPressed: busy ? null : viewModel.signOut,
        child: const Text('Sign out'),
      ),
    ],
    children: [
      if (loading) const Center(child: CircularProgressIndicator()),
      if (message != null) Notice(message!, error: error),
      if (!loading && !loaded)
        OutlinedButton(
          onPressed: load,
          child: const Text('Retry loading profile'),
        ),
      if (!loading && loaded) ...[
        CircleAvatar(
          radius: 38,
          backgroundColor: const Color(0xFFE9E3F7),
          child: Text(
            name.text.isEmpty ? '?' : name.text.characters.first.toUpperCase(),
            style: const TextStyle(fontSize: 32, color: green),
          ),
        ),
        const SizedBox(height: 16),
        Text(viewModel.accounts.email ?? '', textAlign: TextAlign.center),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.verified_outlined, size: 16, color: green),
            const SizedBox(width: 6),
            Text(
              viewModel.accounts.emailVerified
                  ? 'Email verified'
                  : 'Email not yet verified',
              style: const TextStyle(color: green),
            ),
          ],
        ),
        const SizedBox(height: 28),
        Form(
          key: form,
          child: Column(
            children: [
              TextFormField(
                controller: name,
                enabled: !busy,
                validator: validateName,
                decoration: const InputDecoration(labelText: 'Username'),
              ),
              const SizedBox(height: 16),
              BirthField(controller: birth, enabled: !busy),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: role,
                decoration: const InputDecoration(labelText: 'Account role'),
                items: const [
                  DropdownMenuItem(value: 'student', child: Text('Student')),
                  DropdownMenuItem(value: 'mentor', child: Text('Mentor')),
                ],
                onChanged: busy ? null : (v) => setState(() => role = v!),
              ),
              const SizedBox(height: 8),
              const Text(
                'Switch between Student and Mentor anytime. Mentors can teach without qualification approval for now.',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: bio,
                enabled: !busy,
                maxLines: 3,
                maxLength: 500,
                decoration: const InputDecoration(
                  labelText: 'About you',
                  hintText: 'What are you excited to learn or teach?',
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: busy
                    ? null
                    : () {
                        if (form.currentState!.validate()) {
                          viewModel.save(name.text, birth.text, role, bio.text);
                        }
                      },
                child: Text(busy ? 'Please wait…' : 'Save profile'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 28),
        OutlinedButton.icon(
          onPressed: busy
              ? null
              : () async {
                  await AppRouter.openMentorship(context, widget.service);
                  if (mounted) load();
                },
          icon: const Icon(Icons.school_outlined),
          label: const Text('Mentorship and tutor management'),
        ),
        const SizedBox(height: 20),
        const Text(
          'Account settings',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: ink,
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: ListTile(
            leading: Icon(
              Icons.notifications_outlined,
              color: Theme.of(context).colorScheme.primary,
            ),
            title: const Text('Notification Settings'),
            trailing: const Icon(Icons.chevron_right),
            enabled: !busy && !_openingNotificationSettings,
            onTap: busy || _openingNotificationSettings
                ? null
                : openNotificationSettings,
          ),
        ),
        const SizedBox(height: 12),
        OutlinedButton(
          onPressed: busy ? null : () => securityDialog(delete: false),
          child: const Text('Change password'),
        ),
        TextButton(
          onPressed: busy ? null : () => securityDialog(delete: true),
          child: Text(
            'Delete account',
            style: TextStyle(color: Colors.red.shade800),
          ),
        ),
      ],
    ],
  );
}
