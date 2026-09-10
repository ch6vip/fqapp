import 'package:flutter/material.dart';

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
            if (paged) ...[
              Text(
                '第 ${chapterIndex + 1} / $chapterCount 章 · '
                '本章 ${pageIndex == null ? '—' : pageIndex! + 1} / ${pageCount ?? '—'} 页',
                key: const ValueKey('reader-page-number'),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 4),
            ],
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              runSpacing: 4,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(time, key: const ValueKey('reader-clock')),
                    if (status.battery != null) ...[
                      const SizedBox(width: 5),
                      Icon(
                        status.charging
                            ? Icons.battery_charging_full_rounded
                            : Icons.battery_std_rounded,
                        size: 12,
                        color: preset.mutedTextColor,
                      ),
                      Text(
                        '${status.battery}%',
                        key: const ValueKey('reader-battery'),
                      ),
                    ],
                  ],
                ),
                if (!paged) Text('${chapterIndex + 1} / $chapterCount 章'),
                Text(
                  '全书 ${(progress.clamp(0, 1) * 100).toStringAsFixed(1)}%',
                  key: const ValueKey('reader-progress'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
