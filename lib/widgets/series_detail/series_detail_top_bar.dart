import 'package:flutter/material.dart';

import '../home/home_back_button.dart';
import '../home/home_archive.dart';

/// Shared by the header and its subtle backdrop band.
const double seriesDetailTopBarHeight = 56;

/// The work title appears only in the hero, not again in the toolbar.
class SeriesDetailTopBar extends StatelessWidget {
  const SeriesDetailTopBar({super.key, required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: const ValueKey('series-detail-topbar'),
      height: seriesDetailTopBarHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Row(
          children: [
            HomeBackButton(
              key: const ValueKey('series-detail-back'),
              onPressed: onBack,
              size: 48,
            ),
            const Expanded(
              child: HomeCode('STORY ARCHIVE', align: TextAlign.center),
            ),
            const SizedBox(width: 48),
          ],
        ),
      ),
    );
  }
}
