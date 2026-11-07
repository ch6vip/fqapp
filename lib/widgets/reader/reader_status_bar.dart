// Ported from Wenku8_Flutter (revision ebcd7f1):
//   lib/reader_status.dart -> ReaderStatusFooter
//
// Mechanical substitutions:
// - The upstream Android `ReaderStatusFooter.events` EventChannel and its
//   date/battery cache are replaced by fqapp's `ReaderDeviceStatus` snapshot;
//   the clock/battery row keeps the upstream geometry and typography.
// - `AppText` -> `AppText` from `lib/widgets/wenku/src/app_text.dart`.
// - `CupertinoIcons.battery_100` (15) / `bolt_fill` (11) match upstream; they
//   are painted with `Icon` rather than the archive `ArchiveIcon` wrapper
//   because fqapp keeps its own muted reader palette.
// - fqapp keeps its own second slot: the reading progress percentage, the
//   paged page number and the floating player pill are existing product
//   features and stay in this footer.
import 'package:flutter/cupertino.dart';

import '../../services/reader_device.dart';
import '../../services/reader_preferences.dart';
import 'reader_theme.dart';

class ReaderStatusBar extends StatelessWidget {
  final ReaderThemePreset preset;
  final ReaderDeviceStatus status;
  final double progress;
  final int chapterIndex;
  final int chapterCount;
  final bool paged;
  final int? pageIndex;
  final int? pageCount;
  final bool compact;
  final Widget? playerControl;

  const ReaderStatusBar({
    super.key,
    required this.preset,
    required this.status,
    required this.progress,
    required this.chapterIndex,
    required this.chapterCount,
    this.paged = false,
    this.pageIndex,
    this.pageCount,
    this.compact = false,
    this.playerControl,
  });

  @override
  Widget build(BuildContext context) {
    final time =
        '${status.time.hour.toString().padLeft(2, '0')}:'
        '${status.time.minute.toString().padLeft(2, '0')}';
    final size = compact ? 13.0 : 11.0;
    final textStyle = TextStyle(
      color: preset.mutedTextColor,
      fontSize: size,
      height: 1.3,
    );
    return DefaultTextStyle(
      style: textStyle,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (paged && !compact) ...[
              Text(
                '第 ${chapterIndex + 1} / $chapterCount 章 · '
                '本章 ${pageIndex == null ? '—' : pageIndex! + 1} / ${pageCount ?? '—'} 页',
                key: const ValueKey('reader-page-number'),
                textAlign: TextAlign.center,
                style: textStyle,
              ),
              const SizedBox(height: 4),
            ],
            _statusLine(context, time, textStyle),
          ],
        ),
      ),
    );
  }

  // Starting/stopping narration must not resize the viewport mid-page-turn.
  Widget _statusLine(BuildContext context, String time, TextStyle textStyle) =>
      SizedBox(
        height:
            MediaQuery.textScalerOf(
              context,
            ).scale(20).clamp(20, double.infinity) +
            12,
        child: LayoutBuilder(
          builder: (context, constraints) => Row(
            children: [
              Expanded(child: _clockLine(time, textStyle)),
              if (playerControl != null)
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: constraints.maxWidth * 0.65,
                  ),
                  child: playerControl,
                )
              else if (!compact && !paged)
                Flexible(
                  child: Text(
                    '${chapterIndex + 1} / $chapterCount 章',
                    style: textStyle,
                  ),
                ),
              Expanded(
                child: Text(
                  '全书 ${(progress.clamp(0, 1) * 100).toStringAsFixed(1)}%',
                  key: const ValueKey('reader-progress'),
                  textAlign: TextAlign.end,
                  style: textStyle,
                ),
              ),
            ],
          ),
        ),
      );

  /// Upstream footer leading group: time, charging bolt, battery icon and
  /// percentage, all mute so they never compete with the article. Narrow /
  /// large-text viewports drop the battery group instead of overflowing.
  Widget _clockLine(String time, TextStyle textStyle) => LayoutBuilder(
    builder: (context, constraints) {
      final showBattery =
          status.battery != null &&
          constraints.maxWidth >= MediaQuery.textScalerOf(context).scale(80);
      return Row(
        children: [
          Flexible(
            child: Text(
              time,
              key: const ValueKey('reader-clock'),
              style: textStyle,
            ),
          ),
          if (showBattery) ...[
            if (status.charging)
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Icon(
                  CupertinoIcons.bolt_fill,
                  size: 11,
                  color: preset.mutedTextColor,
                ),
              ),
            const SizedBox(width: 5),
            Icon(
              CupertinoIcons.battery_100,
              size: 15,
              color: preset.mutedTextColor,
            ),
            const SizedBox(width: 4),
            Text(
              '${status.battery}%',
              key: const ValueKey('reader-battery'),
              style: textStyle,
            ),
          ],
        ],
      );
    },
  );
}
