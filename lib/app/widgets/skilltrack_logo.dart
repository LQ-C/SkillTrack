import 'package:flutter/material.dart';

class SkillTrackLogo extends StatelessWidget {
  const SkillTrackLogo({super.key});

  @override
  Widget build(BuildContext context) => Image.asset(
    'assets/images/skilltrack-logo.png',
    width: 168,
    height: 52,
    fit: BoxFit.contain,
    alignment: Alignment.centerLeft,
    semanticLabel: 'SkillTrack',
  );
}
