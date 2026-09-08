import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../models/media_item.dart';
import '../home/home_design.dart';

class DetailChapterRow extends StatelessWidget {
  final Chapter chapter;
  final int index;
  final bool current;
  final bool divider;
  final VoidCallback onTap;

  const DetailChapterRow({
    super.key,
    required this.chapter,
    required this.index,
    required this.onTap,
    this.current = false,
    this.divider = true,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Semantics(
      selected: current,
      child: HomePressable(
        semanticLabel: '${chapter.title}${current ? '，上次阅读' : ''}',
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: ExcludeSemantics(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 17),
            decoration: BoxDecoration(
              color: current
                  ? HomePalette.accent.withValues(alpha: 0.065)
                  : null,
              border: divider
                  ? Border(bottom: BorderSide(color: palette.line))
                  : null,
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 36,
                  child: current
                      ? Icon(
                          LucideIcons.book_open,
                          color: palette.accentText,
                          size: 20,
                        )
                      : Text(
                          (index + 1).toString().padLeft(2, '0'),
                          textAlign: TextAlign.center,
                          // This is a decorative ordinal; the full, scalable
                          // chapter title carries the accessible information.
                          textScaler: TextScaler.noScaling,
                          style: TextStyle(
                            color: palette.muted.withValues(alpha: 0.7),
                            fontSize: 12,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    chapter.title,
                    style: TextStyle(
                      color: current ? palette.accentText : palette.ink,
                      fontSize: 14,
                      fontWeight: current ? FontWeight.w600 : FontWeight.w400,
                      height: 1.6,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Icon(
                  LucideIcons.chevron_right,
                  size: 16,
                  color: current ? palette.accentText : palette.muted,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
