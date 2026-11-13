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
    return Row(
      children: [
        Expanded(
          child: HomePressable(
            onTap: onOpen,
            borderRadius: BorderRadius.circular(10),
            semanticLabel: '${now.verb} ${now.item.title}',
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 44),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(homeGutter, 4, 4, 4),
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
                  ],
                ),
              ),
            ),
          ),
        ),
        Semantics(
          button: true,
          label: '隐藏继续阅读',
          onTap: onDismiss,
          excludeSemantics: true,
          child: IconButton(
            tooltip: '隐藏继续阅读',
            onPressed: onDismiss,
            iconSize: 15,
            style: IconButton.styleFrom(
              foregroundColor: palette.muted,
              minimumSize: const Size(48, 44),
              padding: EdgeInsets.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            icon: const Icon(LucideIcons.x),
          ),
        ),
        const SizedBox(width: homeGutter - 10),
      ],
    );
  }
}
