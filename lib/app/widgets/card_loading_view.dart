import 'package:flutter/material.dart';

import '../app_theme.dart';

/// Static skeletons avoid continuous animation while data is loading.
class CardLoadingView extends StatelessWidget {
  const CardLoadingView({
    super.key,
    required this.label,
    this.summaryCount = 0,
    this.showLeading = false,
  });
  final String label;
  final int summaryCount;
  final bool showLeading;

  @override
  Widget build(BuildContext context) => Semantics(
    label: label,
    liveRegion: true,
    child: ExcludeSemantics(
      child: ListView(
        padding: AppTheme.contentPadding,
        children: [
          if (summaryCount > 0) ...[
            Row(
              children: [
                for (var i = 0; i < summaryCount; i++)
                  const Expanded(
                    child: Card(
                      child: Padding(
                        padding: AppTheme.contentPadding,
                        child: Column(
                          children: [
                            _SkeletonLine(fraction: .4, height: 24),
                            SizedBox(height: 12),
                            _SkeletonLine(fraction: .7),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
          ],
          for (var i = 0; i < 3; i++)
            Card(
              margin: const EdgeInsets.only(bottom: 12),
              child: Padding(
                padding: AppTheme.contentPadding,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (showLeading) ...[
                      Container(
                        width: AppTheme.iconSize,
                        height: AppTheme.iconSize,
                        decoration: BoxDecoration(
                          color: Theme.of(
                            context,
                          ).colorScheme.surfaceContainerHigh,
                          borderRadius: AppTheme.cardRadius,
                        ),
                      ),
                      const SizedBox(width: 12),
                    ],
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _SkeletonLine(fraction: .65, height: 18),
                          SizedBox(height: 16),
                          _SkeletonLine(fraction: .9),
                          SizedBox(height: 8),
                          _SkeletonLine(fraction: .75),
                          SizedBox(height: 16),
                          _SkeletonLine(fraction: .4),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

class _SkeletonLine extends StatelessWidget {
  const _SkeletonLine({required this.fraction, this.height = 10});
  final double fraction, height;

  @override
  Widget build(BuildContext context) => FractionallySizedBox(
    widthFactor: fraction,
    child: Container(
      height: height,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: AppTheme.cardRadius,
      ),
    ),
  );
}
