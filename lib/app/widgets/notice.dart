import 'package:flutter/material.dart';
import 'package:skilltrack/app/app_colors.dart';

class Notice extends StatelessWidget {
  const Notice(this.text, {super.key, this.error = false});
  final String text;
  final bool error;
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 16),
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: error ? const Color(0xFFFFEDEA) : const Color(0xFFE2EFE5),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Semantics(
      liveRegion: true,
      child: Text(
        text,
        style: TextStyle(color: error ? const Color(0xFF912C24) : ink),
      ),
    ),
  );
}
