import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import 'home_design.dart';
import 'home_reading_row.dart' show ReadingNow;
import 'home_shelf.dart';

/// The text-only continue row from f329399. Reading history and dismissals
/// still belong to HomePage; this widget only restores their presentation.
class ClassicHomeContinueRow extends StatelessWidget {
  final ReadingNow now;
  final VoidCallback onOpen;
  final VoidCallback onDismiss;

  const ClassicHomeContinueRow({
    super.key,
    required this.now,
    required this.onOpen,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final percent = (now.progress * 100).round();
    return HomePressable(
      onTap: onOpen,
      borderRadius: BorderRadius.circular(10),
      semanticLabel: '${now.verb} ${now.item.title}',
      child: Padding(
        padding: const EdgeInsets.fromLTRB(homeGutter, 10, homeGutter - 6, 2),
        child: Row(
          children: [
            Text(
              now.verb,
              maxLines: 1,
              style: TextStyle(
                fontSize: 11,
                height: 1.2,
                fontWeight: FontWeight.w700,
                color: palette.accentText,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${now.item.title} · ${now.detail}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.3,
                  fontWeight: FontWeight.w600,
                  color: palette.ink,
                ),
              ),
            ),
            if (percent > 0) ...[
              const SizedBox(width: 8),
              Text(
                '$percent%',
                style: TextStyle(
                  fontSize: 11,
                  height: 1.2,
                  fontWeight: FontWeight.w600,
                  color: palette.muted,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
            const SizedBox(width: 2),
            GestureDetector(
              onTap: onDismiss,
              behavior: HitTestBehavior.opaque,
              child: SizedBox(
                width: 32,
                height: 32,
                child: Icon(
                  LucideIcons.x,
                  size: 15,
                  color: palette.muted,
                  semanticLabel: '隐藏继续阅读',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
