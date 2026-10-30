import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../home/home_design.dart';
import 'detail_style.dart';

/// Bottom action bar: secondary actions (听书 / 下载) on the left and the
/// primary read / play call to action as a filled pill on the right.
///
/// Mockup: surface fill with a 1px top line, 8/12/14 padding, two 54dp
/// icon+label items (20dp icon, 10dp muted label) and a 42dp accent pill.
/// The bar is always mounted — while loading it renders disabled instead of
/// disappearing, so the page never jumps when data arrives.
class DetailReadBar extends StatelessWidget {
  final String label;
  final bool opening;

  /// False while the catalogue is loading, empty or failed.
  final bool enabled;

  /// Secondary entries (听书 / 下载) can stay tappable while the catalogue
  /// loads: 下载 opens the download sheet, which also offers the cached copy.
  final bool actionsEnabled;

  final VoidCallback onRead;

  /// Opens the listening page. Hidden when the work has no audio version.
  final VoidCallback? onListen;

  /// Opens the download sheet (整本下载 / 离线缓存).
  final VoidCallback? onDownload;

  /// Running whole-book batch: its progress replaces the static download icon.
  final ({int completed, int total})? download;

  const DetailReadBar({
    super.key,
    required this.label,
    required this.opening,
    required this.onRead,
    this.enabled = true,
    this.actionsEnabled = true,
    this.onListen,
    this.onDownload,
    this.download,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final largeType = MediaQuery.textScalerOf(context).scale(16) > 24;
    final active = enabled && !opening;
    final secondary = <_Secondary>[
      if (onListen != null)
        (
          icon: LucideIcons.headset,
          label: '听书',
          keyName: '听书',
          onTap: onListen!,
          progress: null,
        ),
      if (onDownload != null)
        (
          icon: LucideIcons.download,
          label: '下载',
          keyName: '下载',
          onTap: onDownload!,
          progress: download == null ? null : _fraction(download!),
        ),
    ];
    return RepaintBoundary(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: palette.surface,
          border: Border(top: BorderSide(color: palette.line, width: 1)),
        ),
        child: SafeArea(
          top: false,
          child: Center(
            heightFactor: 1,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 840),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 14),
                child: Row(
                  children: [
                    for (final action in secondary) ...[
                      _SecondaryAction(
                        icon: action.icon,
                        label: action.label,
                        keyName: action.keyName,
                        onTap: action.onTap,
                        progress: action.progress,
                        compact: largeType,
                        enabled: actionsEnabled,
                      ),
                      const SizedBox(width: 6),
                    ],
                    Expanded(
                      child: Semantics(
                        enabled: active,
                        button: true,
                        child: IgnorePointer(
                          ignoring: !active,
                          child: HomePressable(
                            key: const Key('detail_read_button'),
                            onTap: onRead,
                            borderRadius: BorderRadius.circular(999),
                            child: Container(
                              height: 42,
                              alignment: Alignment.center,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              decoration: BoxDecoration(
                                color: active
                                    ? detailAccentFill(palette)
                                    : palette.soft,
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                opening ? '正在打开' : label,
                                textAlign: TextAlign.center,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: active
                                      ? detailOnAccent(palette)
                                      : palette.muted,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                  height: 1.35,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SecondaryAction extends StatelessWidget {
  final IconData icon;
  final String label;

  /// Stable identifier for the widget key: 下载 opens a sheet, not a label.
  final String keyName;
  final VoidCallback onTap;
  final bool compact;
  final bool enabled;

  /// 0..1 while a whole-book batch runs; null falls back to [icon].
  final double? progress;

  const _SecondaryAction({
    required this.icon,
    required this.label,
    required this.keyName,
    required this.onTap,
    required this.compact,
    required this.enabled,
    this.progress,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final progress = this.progress;
    final color = enabled ? palette.ink : palette.muted;
    return IgnorePointer(
      ignoring: !enabled,
      child: HomePressable(
        key: Key('detail_action_$keyName'),
        semanticLabel: label,
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: 54,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (progress == null)
                Icon(icon, size: 20, color: color)
              else
                SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(
                    value: progress.clamp(0.0, 1.0).toDouble(),
                    strokeWidth: 2,
                    color: color,
                  ),
                ),
              if (!compact)
                Text(
                  label,
                  style: TextStyle(
                    color: palette.muted,
                    fontSize: 10,
                    height: 1.4,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

typedef _Secondary = ({
  IconData icon,
  String label,
  String keyName,
  VoidCallback onTap,
  double? progress,
});

double _fraction(({int completed, int total}) download) =>
    download.total == 0 ? 0 : download.completed / download.total;
