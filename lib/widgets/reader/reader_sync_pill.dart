import 'package:flutter/material.dart';

import '../../services/reader_preferences.dart';
import 'reader_chapter_layout.dart';
import 'reader_player_style.dart';

/// Official `nj4/i` 「ReaderSyncTtsButton」 / `nj4/h` view, layout
/// `apktool/res/layout/akc.xml`.
///
/// Shown on a normal text page while this book is being narrated but the spoken
/// sentence is off screen (`d.java:285-320`): 「原进度」 jumps back to the live
/// playback position and follows again (`AudioSyncReaderController.K()`,
/// `:768`); 「从本页听」 restarts playback from this page
/// (`AudioSyncReaderController.L()`, `:702`).
///
/// Colors are `ReaderCommonColor.getGlobalButtonTextColor(theme)` for the text,
/// icons and divider (`nj4/h.java:47-73`); this reader's [ReaderThemePreset]
/// already carries those values as [playerText].
class ReaderSyncPill extends StatelessWidget {
  const ReaderSyncPill({
    super.key,
    required this.onReturnOriginalProgress,
    required this.onListenFromPage,
    this.preset = ReaderThemePreset.light,
  });

  final VoidCallback onReturnOriginalProgress;
  final VoidCallback onListenFromPage;
  final ReaderThemePreset preset;

  /// `akc.xml`: both TextViews are 32dp high.
  static const double height = 32;

  /// `nj4/h.java:88-100`: screen width below 375dp (360dp under the
  /// `indicator_ellipsize_width` config) drops 「原进度」's text. Our
  /// `ReaderBottomBar` config defaults to false, so 375dp is the live value.
  static const double narrowWidth = 375;

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < narrowWidth;
    final foreground = preset.playerText;
    final divider = foreground.withValues(alpha: foreground.a * 0.24);
    return Material(
      key: const ValueKey('reader_sync_pill'),
      color: Colors.transparent,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: height),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _SyncAction(
              key: const ValueKey('reader_sync_return_original'),
              icon: Icons.replay,
              label: '原进度',
              showLabel: !narrow,
              // akc.xml: paddingStart 14dp, paddingEnd 11.5dp.
              padding: const EdgeInsetsDirectional.only(start: 14, end: 11.5),
              color: foreground,
              onTap: onReturnOriginalProgress,
            ),
            // 0.5 × 12dp divider at 24% opacity.
            SizedBox(width: 0.5, height: 12, child: ColoredBox(color: divider)),
            _SyncAction(
              key: const ValueKey('reader_sync_listen_from_here'),
              icon: Icons.headphones,
              label: '从本页听',
              showLabel: true,
              // akc.xml: paddingStart 10dp, paddingEnd 16dp.
              padding: const EdgeInsetsDirectional.only(start: 10, end: 16),
              color: foreground,
              onTap: onListenFromPage,
            ),
          ],
        ),
      ),
    );
  }
}

class _SyncAction extends StatelessWidget {
  const _SyncAction({
    super.key,
    required this.icon,
    required this.label,
    required this.showLabel,
    required this.padding,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool showLabel;
  final EdgeInsetsGeometry padding;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      onTap: onTap,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: padding,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: color),
              // akc.xml: drawablePadding 6dp; dropped together with the text on
              // narrow screens (`nj4/h.java:97`).
              if (showLabel) ...[
                const SizedBox(width: 6),
                Text(
                  label,
                  key: ValueKey('reader_sync_label_$label'),
                  maxLines: 1,
                  softWrap: false,
                  style: TextStyle(color: color, fontSize: 14),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Official `d.java:305-320` `y(page)`: the sync button only belongs on a
/// normal text page. `y()` also rejects chapters whose catalog entry carries
/// `disableTTS`; this client does not model that upstream flag yet, so only the
/// page's own text is checked here.
bool readerSyncPillNormalPage({
  required ReaderChapterLayout? layout,
  required bool paged,
  required int pageIndex,
}) {
  if (layout == null) return false;
  bool isText(ReaderContentBlock block) =>
      !block.isImage && block.text.trim().isNotEmpty;
  if (!paged) {
    // 上下滚动没有「当前页」：本章正文里只要还有可朗读的文字就算正常页。
    return layout.blocks.any(isText);
  }
  if (layout.pages.isEmpty) return false;
  final page = layout.pages[pageIndex.clamp(0, layout.pages.length - 1)];
  return page.fragments.any((fragment) => isText(fragment.block));
}
