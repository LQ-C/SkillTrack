import 'package:flutter/material.dart';

class ContentNotice extends StatelessWidget {
  const ContentNotice(this.message, {super.key, this.error = false});
  final String message;
  final bool error;
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: error ? const Color(0xFFFFEDEA) : const Color(0xFFE2EFE5),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Semantics(liveRegion: true, child: Text(message)),
  );
}
