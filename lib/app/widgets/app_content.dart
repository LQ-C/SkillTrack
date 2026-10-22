import 'package:flutter/material.dart';

import '../app_theme.dart';

/// Keeps mobile content unchanged and readable on wider displays.
class AppContent extends StatelessWidget {
  const AppContent({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: AppTheme.contentMaxWidth),
      child: SizedBox(width: double.infinity, child: child),
    ),
  );
}
