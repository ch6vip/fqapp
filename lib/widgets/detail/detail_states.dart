import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../home/home_design.dart';
import '../home/home_shelf.dart';
import 'detail_style.dart';

/// A section title for the detail page.
///
/// Mockup rhythm: 16dp gutter, 20dp above, 10dp below, a 15dp heading and a
/// 12dp muted action. The trailing action is flexible so a long
/// `完结 共820章 · 全部 ›` ellipsises on a 320dp screen at 3× text instead of
/// overflowing the row.
class DetailSectionHeader extends StatelessWidget {
  final String title;
  final Widget? action;

  const DetailSectionHeader({super.key, required this.title, this.action});

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        homeGutter,
        homeSectionGap,
        homeGutter,
        10,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 15,
                height: 1.5,
                fontWeight: FontWeight.w700,
                color: palette.ink,
              ),
            ),
          ),
          if (action != null) ...[
            const SizedBox(width: 12),
            Flexible(child: action!),
          ],
        ],
      ),
    );
  }
}

/// `＋ 书架` pill in the app bar (and in the desktop side card).
///
/// The mockup pill is plain 12dp text inside a 1px hairline capsule; the old
/// bookmark icon plus a separate refresh icon became this one pill. Refresh is
/// pull-to-refresh on the page itself.
class DetailShelfPill extends StatelessWidget {
  final bool inShelf;
  final bool enabled;
  final VoidCallback onTap;
  final String keyName;

  const DetailShelfPill({
    super.key,
    required this.inShelf,
    required this.enabled,
    required this.onTap,
    this.keyName = 'detail_shelf_button',
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final color = enabled ? palette.ink : palette.muted;
    return IgnorePointer(
      ignoring: !enabled,
      child: HomePressable(
        key: Key(keyName),
        semanticLabel: inShelf ? '已在书架' : '加入书架',
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: palette.line, width: 1),
          ),
          child: Text(
            inShelf ? '✓ 书架' : '＋ 书架',
            style: TextStyle(
              color: color,
              fontSize: 12,
              height: 1.5,
              fontWeight: FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }
}

/// `上次读到 第205章 风起` with a muted relative time on the right.
class DetailResumeRow extends StatelessWidget {
  final String chapterTitle;
  final String? trailing;
  final VoidCallback? onTap;

  const DetailResumeRow({
    super.key,
    required this.chapterTitle,
    this.trailing,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final row = Container(
      key: const Key('detail_resume_row'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: palette.soft,
        borderRadius: BorderRadius.circular(10),
        border: palette.eink ? Border.all(color: palette.line) : null,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '上次读到 $chapterTitle',
              key: const Key('detail_resume_label'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: palette.ink, fontSize: 12, height: 1.5),
            ),
          ),
          if (trailing != null && trailing!.isNotEmpty) ...[
            const SizedBox(width: 8),
            Text(
              trailing!,
              style: TextStyle(color: palette.muted, fontSize: 12, height: 1.5),
            ),
          ],
        ],
      ),
    );
    if (onTap == null) return row;
    return HomePressable(
      semanticLabel: '继续阅读 $chapterTitle',
      onTap: onTap!,
      borderRadius: BorderRadius.circular(10),
      child: row,
    );
  }
}

/// One section failed to load. Each section owns its own retry so a single
/// failed request never takes the whole page down or fails silently.
class DetailInlineError extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const DetailInlineError({
    super.key,
    required this.message,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Padding(
      key: const Key('detail_inline_error'),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            message,
            style: TextStyle(color: palette.muted, fontSize: 13, height: 1.5),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: onRetry,
            style: detailOutlineButtonStyle(
              palette,
              minimumSize: const Size(88, 40),
            ),
            icon: const Icon(LucideIcons.refresh_cw, size: 16),
            label: const Text('重试'),
          ),
        ],
      ),
    );
  }
}

/// Static skeleton blocks shown while the page loads.
///
/// Deliberately unanimated: an e-ink screen ghosts on every moving pixel, and
/// a pulsing placeholder is exactly the motion it must not get.
class DetailSkeleton extends StatelessWidget {
  const DetailSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    Widget bar(double widthFactor, double height) => FractionallySizedBox(
      alignment: Alignment.centerLeft,
      widthFactor: widthFactor,
      child: Container(
        height: height,
        decoration: BoxDecoration(
          color: palette.soft,
          borderRadius: BorderRadius.circular(6),
        ),
      ),
    );
    Widget section({required double title, required List<double> lines}) =>
        Padding(
          padding: const EdgeInsets.fromLTRB(
            homeGutter,
            homeSectionGap,
            homeGutter,
            0,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              bar(title, 16),
              const SizedBox(height: 10),
              for (final line in lines) ...[
                bar(line, 12),
                const SizedBox(height: 8),
              ],
            ],
          ),
        );
    return Column(
      key: const Key('detail_skeleton'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        section(title: 0.16, lines: const [1, 0.94, 0.72]),
        section(title: 0.16, lines: const [0.9, 0.86, 0.9]),
        section(title: 0.12, lines: const [1, 0.82]),
      ],
    );
  }
}

/// One row of the download sheet (整本下载 / 离线缓存).
///
/// The mockup keeps the phone rest layout to a single 下载 item, so the
/// whole-book batch and the cached copy fold into this sheet.
class DetailSheetOption extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool enabled;
  final VoidCallback onTap;

  const DetailSheetOption({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final color = enabled ? palette.ink : palette.muted;
    return IgnorePointer(
      ignoring: !enabled,
      child: HomePressable(
        semanticLabel: title,
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Row(
            children: [
              Icon(icon, size: 20, color: color),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(color: color, fontSize: 14, height: 1.4),
                    ),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: palette.muted,
                        fontSize: 12,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
