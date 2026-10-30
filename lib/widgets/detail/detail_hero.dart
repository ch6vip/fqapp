import 'package:flutter/material.dart';
import '../../models/book_detail.dart';
import '../../models/media_item.dart';
import '../home/home_design.dart';
import 'detail_cover_tile.dart';
import 'detail_style.dart';

/// Detail-page masthead: the cover on the left with the title, the author /
/// category meta line, the single rating, the rank pill, the update line and
/// the tags stacked to its right.
///
/// Mockup: 6/16 padding, a 14 gap, a 19/1.3 title, and a 5dp gap between the
/// rows of `.hcol`. Each row appears only when it has data. The title
/// deliberately has no `maxLines` so it always wraps in full rather than
/// truncating.
class DetailHero extends StatelessWidget {
  final MediaItem item;
  final BookDetail? detail;

  /// Opens the author's home. Only called when the payload carried an id.
  final VoidCallback? onOpenAuthor;

  /// Last chapter title used by the `更新至 …` line; the page resolves it from
  /// `BookDetail.lastChapterTitle` or the directory.
  final String? lastChapterTitle;

  /// 桌面两栏布局：去掉顶部色块，封面放大并整体居中。
  final bool desktop;
  final bool compactDesktop;

  const DetailHero({
    super.key,
    required this.item,
    this.detail,
    this.onOpenAuthor,
    this.lastChapterTitle,
    this.desktop = false,
    this.compactDesktop = false,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final title = detail?.title.isNotEmpty == true ? detail!.title : item.title;
    // A 3x accessibility scale cannot fit a cover beside the text on a narrow
    // phone, so the masthead stacks instead of squeezing both into one row.
    final stacked = MediaQuery.textScalerOf(context).scale(16) > 26;
    final centered = desktop && !compactDesktop;
    final rows = _rows(palette, centered: centered);
    final info = Column(
      crossAxisAlignment: centered
          ? CrossAxisAlignment.center
          : CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2, bottom: 1),
          child: Text(
            title,
            key: const Key('detail_book_title'),
            style: TextStyle(
              color: palette.ink,
              fontSize: desktop ? 22 : 19,
              fontWeight: FontWeight.w700,
              height: 1.3,
            ),
          ),
        ),
        for (var i = 0; i < rows.length; i++) ...[
          SizedBox(height: i == rows.length - 1 ? 7 : 5),
          rows[i],
        ],
      ],
    );
    final cover = DetailCoverTile(
      item: item,
      desktop: desktop,
      compact: compactDesktop,
    );

    return Padding(
      padding: desktop
          ? const EdgeInsets.fromLTRB(0, 16, 0, 0)
          : const EdgeInsets.fromLTRB(16, 6, 16, 0),
      child: (stacked || centered)
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(child: cover),
                const SizedBox(height: 18),
                info,
              ],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                cover,
                const SizedBox(width: 14),
                Expanded(child: info),
              ],
            ),
    );
  }

  /// The optional meta / rating / rank / update / tags rows, in mockup order.
  List<Widget> _rows(HomePalette palette, {required bool centered}) {
    final authorName = detail?.author.name.isNotEmpty == true
        ? detail!.author.name
        : item.author.trim();
    final metaParts = detail?.metaParts ?? const <String>[];
    final score = detail?.scoreLabel ?? '';
    final readers = detail?.readLabel ?? '';
    final rank = detail?.rankLabel ?? '';
    final latest = lastChapterTitle?.trim() ?? '';
    final updating = detail?.creationStatus == 1 && latest.isNotEmpty
        ? '更新至 $latest'
        : '';
    final tags = detail?.tags ?? const <String>[];
    return [
      if (authorName.isNotEmpty || metaParts.isNotEmpty)
        _MetaLine(
          palette: palette,
          author: detail?.author,
          fallbackAuthor: item.author,
          parts: metaParts,
          onOpenAuthor: onOpenAuthor,
          centered: centered,
        ),
      if (score.isNotEmpty || readers.isNotEmpty)
        _RatingLine(
          palette: palette,
          score: score,
          readers: readers,
          centered: centered,
        ),
      if (rank.isNotEmpty) _RankPill(palette: palette, label: rank),
      if (updating.isNotEmpty)
        Text(
          updating,
          key: const Key('detail_update_line'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: palette.muted, fontSize: 12, height: 1.5),
        ),
      if (tags.isNotEmpty) _HeroTags(tags: tags, centered: centered),
    ];
  }
}

/// `科幻热榜 第3名` — rank pill in the hero's right column.
class _RankPill extends StatelessWidget {
  final HomePalette palette;
  final String label;

  const _RankPill({required this.palette, required this.label});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        key: const Key('detail_rank_pill'),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
        decoration: BoxDecoration(
          color: detailRankFill(palette),
          borderRadius: BorderRadius.circular(99),
          border: palette.eink
              ? Border.all(color: palette.line, width: 1)
              : null,
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: palette.accentText,
            fontSize: 11,
            fontWeight: FontWeight.w500,
            height: 1.5,
          ),
        ),
      ),
    );
  }
}

/// Genre tags in the hero: one clipped line on phones, a centred wrap on the
/// wide desktop masthead.
class _HeroTags extends StatelessWidget {
  final List<String> tags;
  final bool centered;

  const _HeroTags({required this.tags, required this.centered});

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    Widget pill(String tag) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 2),
      decoration: BoxDecoration(
        color: palette.soft,
        borderRadius: BorderRadius.circular(99),
        border: palette.eink ? Border.all(color: palette.line) : null,
      ),
      child: Text(
        tag,
        maxLines: 1,
        style: TextStyle(color: palette.muted, fontSize: 11, height: 1.5),
      ),
    );
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < tags.length; i++) ...[
          if (i > 0) const SizedBox(width: 6),
          pill(tags[i]),
        ],
      ],
    );
    return SizedBox(
      key: const Key('detail_hero_tags'),
      height: 20.5,
      child: centered
          ? Center(child: row)
          : ClipRect(
              child: OverflowBox(
                alignment: Alignment.centerLeft,
                maxWidth: double.infinity,
                child: row,
              ),
            ),
    );
  }
}

/// `作者 › · 分类 · 完结 · 238万字`. The author is the only tappable part.
class _MetaLine extends StatelessWidget {
  final HomePalette palette;
  final BookAuthor? author;
  final String fallbackAuthor;
  final List<String> parts;
  final VoidCallback? onOpenAuthor;
  final bool centered;

  const _MetaLine({
    required this.palette,
    required this.author,
    required this.fallbackAuthor,
    required this.parts,
    required this.onOpenAuthor,
    required this.centered,
  });

  @override
  Widget build(BuildContext context) {
    final name = author?.name.isNotEmpty == true
        ? author!.name
        : fallbackAuthor.trim();
    final tail = parts.join(' · ');
    if (name.isEmpty && tail.isEmpty) return const SizedBox.shrink();
    final canOpen =
        name.isNotEmpty &&
        author?.id.isNotEmpty == true &&
        onOpenAuthor != null;
    final style = TextStyle(color: palette.muted, fontSize: 12, height: 1.5);
    final children = <Widget>[
      if (name.isNotEmpty)
        canOpen
            ? HomePressable(
                semanticLabel: '查看 $name 的主页',
                onTap: onOpenAuthor!,
                borderRadius: BorderRadius.circular(4),
                child: Text(
                  '$name ›',
                  key: const Key('detail_author_name'),
                  style: style.copyWith(color: palette.ink),
                ),
              )
            : Text(name, style: style),
      if (tail.isNotEmpty)
        Text(
          '${name.isEmpty ? '' : ' · '}$tail',
          key: const Key('detail_meta_line'),
          style: style,
        ),
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 0),
      child: centered
          ? Wrap(
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: children,
            )
          : Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: children,
            ),
    );
  }
}

/// `★ 8.7 · 12.4万人在读` — the one rating on the page.
class _RatingLine extends StatelessWidget {
  final HomePalette palette;
  final String score;
  final String readers;
  final bool centered;

  const _RatingLine({
    required this.palette,
    required this.score,
    required this.readers,
    required this.centered,
  });

  @override
  Widget build(BuildContext context) {
    if (score.isEmpty && readers.isEmpty) return const SizedBox.shrink();
    final readLabel = readers.isEmpty
        ? ''
        : (readers.endsWith('在读') ? readers : '$readers人在读');
    return Padding(
      padding: EdgeInsets.zero,
      child: Row(
        key: const Key('detail_rating_line'),
        mainAxisSize: centered ? MainAxisSize.min : MainAxisSize.max,
        children: [
          if (score.isNotEmpty) ...[
            Text(
              '★',
              style: TextStyle(
                color: detailStarColor(palette),
                fontSize: 12,
                height: 1.5,
              ),
            ),
            const SizedBox(width: 4),
            Text(
              score,
              style: TextStyle(
                color: palette.ink,
                fontSize: 14,
                fontWeight: FontWeight.w500,
                height: 1.5,
                fontFeatures: detailNumericFeatures,
              ),
            ),
          ],
          if (score.isNotEmpty && readLabel.isNotEmpty)
            Text(' · ', style: TextStyle(color: palette.muted, fontSize: 12)),
          if (readLabel.isNotEmpty)
            Flexible(
              child: Text(
                readLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: palette.muted, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }
}
