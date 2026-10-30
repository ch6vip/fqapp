import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../home/home_design.dart';
import 'detail_style.dart';

/// Bottom action bar: secondary actions (听书 / 下载) on the left and the
/// primary read / play call to action as a filled pill on the right.
///
/// The bar itself is always mounted — while loading it renders disabled
/// instead of disappearing, so the page never jumps when data arrives.
class DetailReadBar extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool opening;

  /// False while the catalogue is loading, empty or failed.
  final bool enabled;
  final VoidCallback onRead;

  /// Opens the listening page. Hidden when the work has no audio version.
  final VoidCallback? onListen;

  /// Starts (or stops) the whole-book download.
  final VoidCallback? onDownload;

  /// Running whole-book batch: its progress replaces the static download icon.
  final ({int completed, int total})? download;

  const DetailReadBar({
    super.key,
    required this.label,
    required this.icon,
    required this.opening,
    required this.onRead,
    this.enabled = true,
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
          icon: LucideIcons.headphones,
          label: '听书',
          keyName: '听书',
          onTap: onListen!,
          progress: null,
        ),
      if (onDownload != null)
        (
          icon: LucideIcons.download,
          label: download == null
              ? '下载'
              : '缓存 ${download!.completed}/${download!.total}',
          keyName: '下载',
          onTap: onDownload!,
          progress: download == null ? null : _fraction(download!),
        ),
    ];
    return RepaintBoundary(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: palette.surface,
          border: Border(top: BorderSide(color: palette.line, width: 0.6)),
        ),
        child: SafeArea(
          top: false,
          child: Center(
            heightFactor: 1,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 840),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
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
                        enabled: enabled,
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
                              constraints: const BoxConstraints(minHeight: 46),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 12,
                              ),
                              decoration: BoxDecoration(
                                color: active
                                    ? detailAccentFill(palette)
                                    : palette.soft,
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  if (!largeType) ...[
                                    if (opening)
                                      SizedBox.square(
                                        dimension: 17,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: detailOnAccent(palette),
                                        ),
                                      )
                                    else
                                      Icon(
                                        icon,
                                        color: active
                                            ? detailOnAccent(palette)
                                            : palette.muted,
                                        size: 18,
                                      ),
                                    const SizedBox(width: 7),
                                  ],
                                  Flexible(
                                    child: Text(
                                      opening ? '正在打开' : label,
                                      textAlign: TextAlign.center,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: active
                                            ? detailOnAccent(palette)
                                            : palette.muted,
                                        fontSize: 15,
                                        fontWeight: FontWeight.w700,
                                        height: 1.4,
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

  /// Stable identifier for the widget key: a running download puts its progress
  /// into [label], so the label itself cannot be the key.
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
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (progress == null)
                Icon(icon, size: 19, color: color)
              else
                SizedBox.square(
                  dimension: 19,
                  child: CircularProgressIndicator(
                    value: progress.clamp(0.0, 1.0).toDouble(),
                    strokeWidth: 2,
                    color: color,
                  ),
                ),
              if (!compact) ...[
                const SizedBox(height: 2),
                Text(
                  label,
                  style: TextStyle(color: color, fontSize: 10.5, height: 1.25),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A secondary action: what it shows, what it opens, and — for a running
/// whole-book download — the batch progress the entry renders in place of its
/// static icon.
typedef _Secondary = ({
  IconData icon,
  String label,
  String keyName,
  VoidCallback onTap,
  double? progress,
});

double _fraction(({int completed, int total}) download) =>
    download.total == 0 ? 0 : download.completed / download.total;
