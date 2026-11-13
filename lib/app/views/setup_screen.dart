import 'package:flutter/material.dart';
import 'package:skilltrack/app/app_colors.dart';
import 'package:skilltrack/app/widgets/page_shell.dart';

class SetupScreen extends StatelessWidget {
  const SetupScreen({super.key, required this.message});
  final String message;
  @override
  Widget build(BuildContext context) => PageShell(
    title: 'Your next chapter starts here.',
    subtitle: 'Learn with purpose. Grow with people.',
    children: [
      const Icon(Icons.hub_outlined, size: 60, color: green),
      const SizedBox(height: 20),
      const Text(
        'Connect your account service',
        style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 12),
      Text(message),
      const SizedBox(height: 20),
      const Text(
        'No account has been created. Account features will become available after setup.',
      ),
    ],
  );
}
