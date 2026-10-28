import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

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
    return DefaultTextStyle(
      style: Theme.of(context).textTheme.bodySmall!.copyWith(
        color: preset.mutedTextColor,
        fontSize: 10,
        height: 1.4,
      ),
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
              ),
              const SizedBox(height: 4),
            ],
            _statusLine(context, time),
          ],
        ),
      ),
    );
  }

  // Starting/stopping narration must not resize the viewport mid-page-turn.
  Widget _statusLine(BuildContext context, String time) => SizedBox(
    height:
        MediaQuery.textScalerOf(context).scale(20).clamp(20, double.infinity) +
        12,
    child: LayoutBuilder(
      builder: (context, constraints) => Row(
        children: [
          Expanded(child: _playerClock(time)),
          if (playerControl != null)
            ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: constraints.maxWidth * 0.65,
              ),
              child: playerControl,
            )
          else if (!compact && !paged)
            Flexible(child: Text('${chapterIndex + 1} / $chapterCount 章')),
          Expanded(
            child: Text(
              '全书 ${(progress.clamp(0, 1) * 100).toStringAsFixed(1)}%',
              key: const ValueKey('reader-progress'),
              textAlign: TextAlign.end,
            ),
          ),
        ],
      ),
    ),
  );

  Widget _playerClock(String time) => LayoutBuilder(
    builder: (context, constraints) => Row(
      children: [
        Flexible(child: Text(time, key: const ValueKey('reader-clock'))),
        if (!compact &&
            status.battery != null &&
            constraints.maxWidth >=
                MediaQuery.textScalerOf(context).scale(80)) ...[
          const SizedBox(width: 5),
          Icon(
            status.charging
                ? LucideIcons.battery_charging
                : LucideIcons.battery_medium,
            size: 13,
            color: preset.mutedTextColor,
          ),
          Text('${status.battery}%', key: const ValueKey('reader-battery')),
        ],
      ],
    ),
  );
}
