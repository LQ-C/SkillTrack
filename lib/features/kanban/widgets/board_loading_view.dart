import 'package:flutter/material.dart';

class BoardLoadingView extends StatelessWidget {
  const BoardLoadingView({super.key});
  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Loading your board',
    child: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _placeholder(context, height: 104),
        const SizedBox(height: 16),
        _placeholder(context, height: 42, width: 150),
        const SizedBox(height: 12),
        for (var index = 0; index < 3; index++) ...[
          _placeholder(context, height: 118),
          const SizedBox(height: 12),
        ],
      ],
    ),
  );

  Widget _placeholder(
    BuildContext context, {
    required double height,
    double? width,
  }) => Align(
    alignment: Alignment.centerLeft,
    child: Container(
      width: width ?? double.infinity,
      height: height,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
    ),
  );
}
