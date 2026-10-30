import 'package:flutter/material.dart';

import '../../models/media_item.dart';
import '../home/home_design.dart';

/// One row of the 目录 preview.
///
/// Mockup: 9dp vertical padding, a 1px separator, 13dp text, `已读` on muted
/// rows before the saved chapter and `读到这里` on the accent current row.
class DetailChapterRow extends StatelessWidget {
  final Chapter chapter;
  final bool current;

  /// A chapter the reader has already finished (before the current one).
  final bool read;
  final bool divider;
  final VoidCallback onTap;

  const DetailChapterRow({
    super.key,
    required this.chapter,
    required this.onTap,
    this.current = false,
    this.read = false,
    this.divider = true,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final label = current ? '读到这里' : (read ? '已读' : null);
    return Semantics(
      selected: current,
      child: HomePressable(
        semanticLabel: '${chapter.title}${current ? '，上次阅读' : ''}',
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: ExcludeSemantics(
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 9),
            decoration: BoxDecoration(
              border: divider
                  ? Border(bottom: BorderSide(color: palette.line))
                  : null,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    chapter.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: current ? palette.accentText : palette.ink,
                      fontSize: 13,
                      fontWeight: current ? FontWeight.w500 : FontWeight.w400,
                      height: 1.5,
                    ),
                  ),
                ),
                if (label != null) ...[
                  const SizedBox(width: 12),
                  Text(
                    label,
                    style: TextStyle(
                      color: current ? palette.accentText : palette.muted,
                      fontSize: 13,
                      fontWeight: current ? FontWeight.w500 : FontWeight.w400,
                      height: 1.5,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
