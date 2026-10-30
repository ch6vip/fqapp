import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../home/home_design.dart';
import '../home/home_shelf.dart';
import 'detail_style.dart';

/// A section title for the detail page.
///
/// Same rhythm as the home `HomeSectionHeader` (16dp gutter, 20dp above,
/// 12dp below), but the trailing action is flexible so a long
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
        homeHeaderGap,
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
                fontSize: 16.5,
                height: 1.25,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.2,
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
/// The old bookmark icon plus a separate refresh icon became one pill; the
/// refresh action is now pull-to-refresh on the page itself.
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
    return IgnorePointer(
      ignoring: !enabled,
      child: HomePressable(
        key: Key(keyName),
        semanticLabel: inShelf ? '已在书架' : '加入书架',
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
          decoration: BoxDecoration(
            color: inShelf ? palette.soft : Colors.transparent,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: inShelf ? palette.line : palette.muted,
              width: 0.8,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                inShelf ? LucideIcons.check : LucideIcons.plus,
                size: 15,
                color: enabled ? palette.ink : palette.muted,
              ),
              const SizedBox(width: 3),
              Text(
                '书架',
                style: TextStyle(
                  color: enabled ? palette.ink : palette.muted,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// `上次读到 第205章 风起` — the reader's place, right under the hero.
///
/// It used to be an 11sp caption in the bottom action bar; the redesign gives
/// it a soft rounded row and normal type so resuming is the obvious next tap.
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
          Icon(LucideIcons.clock_arrow_up, size: 15, color: palette.muted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '上次读到 $chapterTitle',
              key: const Key('detail_resume_label'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: palette.ink, fontSize: 13, height: 1.4),
            ),
          ),
          if (trailing != null && trailing!.isNotEmpty) ...[
            const SizedBox(width: 8),
            Text(
              trailing!,
              style: TextStyle(color: palette.muted, fontSize: 12),
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
  final VoidCallback? onReadCached;

  const DetailInlineError({
    super.key,
    required this.message,
    required this.onRetry,
    this.onReadCached,
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
            style: TextStyle(color: palette.muted, fontSize: 13, height: 1.6),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (onReadCached != null)
                FilledButton.icon(
                  key: const Key('detail_read_cached'),
                  onPressed: onReadCached,
                  style: detailPrimaryButtonStyle(
                    palette,
                    minimumSize: const Size(110, 42),
                  ),
                  icon: const Icon(LucideIcons.book_open, size: 16),
                  label: const Text('从缓存阅读'),
                ),
              OutlinedButton.icon(
                onPressed: onRetry,
                style: detailOutlineButtonStyle(
                  palette,
                  minimumSize: const Size(88, 42),
                ),
                icon: const Icon(LucideIcons.refresh_cw, size: 16),
                label: const Text('重试'),
              ),
            ],
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
              const SizedBox(height: homeHeaderGap),
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
