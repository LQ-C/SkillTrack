import 'package:flutter/material.dart';

import '../../../app/widgets/card_loading_view.dart';

class BoardLoadingView extends StatelessWidget {
  const BoardLoadingView({super.key});

  @override
  Widget build(BuildContext context) =>
      const CardLoadingView(label: 'Loading your board', summaryCount: 1);
}
