import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../home/home_design.dart';

/// Bottom action bar: secondary actions (听书 / 下载) on the left and the
/// primary read / play call to action as a filled pill on the right.
class DetailReadBar extends StatelessWidget {
  final String label;
  final String? resumeTitle;
  final IconData icon;
  final bool opening;
  final VoidCallback onRead;

  /// Opens the listening page. Hidden when the work has no audio version.
  final VoidCallback? onListen;

  /// Starts (or stops) the whole-book download. The range sheet stays with the
  /// reader, where picking a batch size still makes sense.
  final VoidCallback? onDownload;

  /// Running whole-book batch: its progress replaces the static download icon.
  final ({int completed, int total})? download;

  const DetailReadBar({
    super.key,
    required this.label,
    required this.icon,
    required this.opening,
    required this.onRead,
    this.resumeTitle,
    this.onListen,
    this.onDownload,
    this.download,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final largeType = MediaQuery.textScalerOf(context).scale(16) > 24;
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
          border: Border(
            top: BorderSide(
              color: palette.line,
              width: 0.6,
            ),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(
                alpha: palette.dark ? 0.28 : 0.04,
              ),
              blurRadius: 16,
              offset: const Offset(0, -4),
            ),
          ],
        ),
        child: SafeArea(
          top: false,
          child: Center(
            heightFactor: 1,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 840),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (resumeTitle != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Row(
                        children: [
                          Icon(
                            LucideIcons.clock_arrow_up,
                            size: 13,
                            color: palette.muted,
                          ),
                          const SizedBox(width: 7),
                          Expanded(
                            child: Text(
                              '上次读到：$resumeTitle',
                              key: const Key('detail_resume_label'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: palette.muted,
                                fontSize: 11,
                                height: 1.4,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  Row(
                    children: [
                      for (final action in secondary) ...[
                        _SecondaryAction(
                          icon: action.icon,
                          label: action.label,
                          keyName: action.keyName,
                          onTap: action.onTap,
                          progress: action.progress,
                          compact: largeType,
                        ),
                        Container(
                          width: 0.5,
                          height: 22,
                          color: palette.line,
                          margin: const EdgeInsets.symmetric(horizontal: 14),
                        ),
                      ],
                      Expanded(
                        child: Semantics(
                          enabled: !opening,
                          child: IgnorePointer(
                            ignoring: opening,
                            child: HomePressable(
                              key: const Key('detail_read_button'),
                              onTap: onRead,
                              borderRadius: BorderRadius.circular(999),
                              child: Container(
                                constraints: const BoxConstraints(
                                  minHeight: 48,
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 13,
                                ),
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    colors: opening
                                        ? [palette.muted, palette.muted]
                                        : const [
                                            HomePalette.accent,
                                            Color(0xFFE4432E),
                                          ],
                                  ),
                                  borderRadius: BorderRadius.circular(999),
                                  boxShadow: opening
                                      ? null
                                      : [
                                          BoxShadow(
                                            color: HomePalette.accent
                                                .withValues(alpha: 0.20),
                                            blurRadius: 14,
                                            offset: const Offset(0, 5),
                                          ),
                                        ],
                                ),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    if (!largeType) ...[
                                      if (opening)
                                        const SizedBox.square(
                                          dimension: 17,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Colors.white,
                                          ),
                                        )
                                      else
                                        Icon(
                                          icon,
                                          color: Colors.white,
                                          size: 19,
                                        ),
                                      const SizedBox(width: 8),
                                    ],
                                    Flexible(
                                      child: Text(
                                        opening ? '正在打开' : label,
                                        textAlign: TextAlign.center,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 15.5,
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

  /// 0..1 while a whole-book batch runs; null falls back to [icon].
  final double? progress;

  const _SecondaryAction({
    required this.icon,
    required this.label,
    required this.keyName,
    required this.onTap,
    required this.compact,
    this.progress,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final progress = this.progress;
    return HomePressable(
      key: Key('detail_action_$keyName'),
      semanticLabel: label,
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (progress == null)
              Icon(icon, size: 19, color: palette.ink)
            else
              SizedBox.square(
                dimension: 19,
                child: CircularProgressIndicator(
                  value: progress.clamp(0.0, 1.0).toDouble(),
                  strokeWidth: 2,
                  color: palette.ink,
                ),
              ),
            if (!compact) ...[
              const SizedBox(height: 3),
              Text(
                label,
                style: TextStyle(
                  color: palette.ink,
                  fontSize: 10.5,
                  height: 1.25,
                ),
              ),
            ],
          ],
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
