import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../services/poster_cache.dart';
import '../../models/book_detail.dart';
import '../../models/series_detail.dart';
import '../home/home_design.dart';

/// Author row: avatar, pen name, level badge, tagline and follow action.
class DetailAuthorRow extends StatelessWidget {
  final BookAuthor author;

  /// Opens the author's home. The backend exposes no follow endpoint, so this
  /// row offers a route to the author rather than a follow action that could
  /// not work.
  final VoidCallback? onOpenAuthor;

  const DetailAuthorRow({super.key, required this.author, this.onOpenAuthor});

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final avatar = ClipOval(
      child: SizedBox.square(
        dimension: 38,
        child: author.avatar.isEmpty
            ? ColoredBox(
                color: palette.soft,
                child: Icon(LucideIcons.user, size: 20, color: palette.muted),
              )
            : CachedNetworkImage(
                cacheManager: PosterCache.instance,
                imageUrl: author.avatar,
                fit: BoxFit.cover,
                // 38dp avatar; decode at 2×. CachedNetworkImage also adds
                // the disk cache a bare Image.network lacks.
                memCacheWidth: 76,
                errorWidget: (context, _, _) => ColoredBox(
                  color: palette.soft,
                  child: Icon(LucideIcons.user, size: 20, color: palette.muted),
                ),
              ),
      ),
    );
    final identity = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                author.name,
                key: const Key('detail_author_name'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: palette.ink,
                  fontSize: 14.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (author.title.isNotEmpty) ...[
              const SizedBox(width: 6),
              _LevelBadge(text: author.title),
            ],
          ],
        ),
        const SizedBox(height: 3),
        Text(
          onOpenAuthor == null ? '关注我，掌握书籍最新动态' : '查看作者主页和全部作品',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: palette.muted, fontSize: 11.5, height: 1.3),
        ),
      ],
    );

    final row = Row(
      children: [
        avatar,
        const SizedBox(width: 11),
        Expanded(child: identity),
        if (onOpenAuthor != null) ...[
          const SizedBox(width: 10),
          _AuthorLinkChip(),
        ],
      ],
    );
    if (onOpenAuthor == null) return row;
    return HomePressable(
      key: const Key('detail_author_row'),
      semanticLabel: '查看 ${author.name} 的主页',
      onTap: onOpenAuthor!,
      borderRadius: BorderRadius.circular(12),
      child: row,
    );
  }
}

class _LevelBadge extends StatelessWidget {
  final String text;

  const _LevelBadge({required this.text});

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    // The official badge is orange; reuse the accent family so it still reads
    // as a rank chip in both themes.
    final color = palette.dark
        ? const Color(0xFFE9A23B)
        : const Color(0xFFD98324);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w600,
          height: 1.4,
        ),
      ),
    );
  }
}

/// Trailing affordance that opens the author's home.
///
/// The official client shows a 关注 button here, but the backend exposes no
/// follow endpoint, so a button that looked like 关注 would be a dead control.
/// This offers the one action that actually works.
class _AuthorLinkChip extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: palette.accentText.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '主页',
            style: TextStyle(
              color: palette.accentText,
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 2),
          Icon(LucideIcons.chevron_right, size: 14, color: palette.accentText),
        ],
      ),
    );
  }
}

/// One statistic rendered in the three-column row under the author.
class DetailStat {
  const DetailStat({
    required this.value,
    required this.label,
    this.icon,
    this.stars = 0,
    this.accent = false,
  });

  final String value;
  final String label;
  final IconData? icon;

  /// Filled-star count (0-5) rendered under [value]; 0 hides the row.
  final double stars;
  final bool accent;

  bool get isEmpty => value.trim().isEmpty && label.trim().isEmpty;
}

/// Rank / readers / rating, separated by hairline dividers.
class DetailStatsRow extends StatelessWidget {
  final List<DetailStat> stats;

  const DetailStatsRow({super.key, required this.stats});

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final visible = stats
        .where((stat) => !stat.isEmpty)
        .toList(growable: false);
    if (visible.isEmpty) return const SizedBox.shrink();
    final children = <Widget>[];
    for (var index = 0; index < visible.length; index++) {
      if (index > 0) {
        children.add(Container(width: 0.5, height: 34, color: palette.line));
      }
      children.add(Expanded(child: _StatCell(stat: visible[index])));
    }
    return Container(
      key: const Key('detail_stats_row'),
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(
        border: Border.symmetric(
          horizontal: BorderSide(color: palette.line, width: 0.5),
        ),
      ),
      child: Row(children: children),
    );
  }
}

class _StatCell extends StatelessWidget {
  final DetailStat stat;

  const _StatCell({required this.stat});

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final valueColor = stat.accent ? palette.accentText : palette.ink;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (stat.icon != null) ...[
            Icon(
              stat.icon,
              size: 17,
              color: stat.accent ? palette.accentText : palette.muted,
            ),
            const SizedBox(height: 4),
          ],
          Text(
            stat.value,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: valueColor,
              fontSize: 15.5,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.2,
            ),
          ),
          if (stat.stars > 0) ...[
            const SizedBox(height: 2),
            _StarRow(stars: stat.stars),
          ],
          const SizedBox(height: 3),
          Text(
            stat.label,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: palette.muted, fontSize: 11, height: 1.3),
          ),
        ],
      ),
    );
  }
}

/// Five stars filled to [stars] (halves supported), used by the stats row and
/// the review card.
class _StarRow extends StatelessWidget {
  final double stars;
  final double size;

  const _StarRow({required this.stars, this.size = 11});

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var index = 1; index <= 5; index++)
          Icon(
            stars >= index
                ? LucideIcons.star
                : (stars >= index - 0.5
                      ? LucideIcons.star_half
                      : LucideIcons.star),
            size: size,
            color: stars >= index - 0.5 ? HomePalette.accent : palette.line,
          ),
      ],
    );
  }
}

/// Half-star row exposed for the review card.
class DetailStarRow extends StatelessWidget {
  final double stars;
  final double size;

  const DetailStarRow({super.key, required this.stars, this.size = 11});

  @override
  Widget build(BuildContext context) => _StarRow(stars: stars, size: size);
}

/// Genre tags as rounded chips.
class DetailTagChips extends StatelessWidget {
  final List<String> tags;

  const DetailTagChips({super.key, required this.tags});

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    if (tags.isEmpty) return const SizedBox.shrink();
    return Wrap(
      key: const Key('detail_tag_chips'),
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final tag in tags)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: palette.soft,
              borderRadius: BorderRadius.circular(7),
            ),
            child: Text(
              tag,
              style: TextStyle(
                color: palette.muted,
                fontSize: 12,
                height: 1.35,
              ),
            ),
          ),
      ],
    );
  }
}

/// `查看目录  完结 共1157章 ›` row that opens the full catalog.
class DetailDirectoryRow extends StatelessWidget {
  final String trailing;
  final VoidCallback onTap;

  const DetailDirectoryRow({
    super.key,
    required this.trailing,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return HomePressable(
      key: const Key('detail_directory_button'),
      semanticLabel: '查看目录',
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Row(
          children: [
            Text(
              '查看目录',
              style: TextStyle(
                color: palette.ink,
                fontSize: 16,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.2,
              ),
            ),
            const Spacer(),
            if (trailing.isNotEmpty)
              Flexible(
                child: Text(
                  trailing,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: palette.muted, fontSize: 12),
                ),
              ),
            const SizedBox(width: 4),
            Icon(LucideIcons.chevron_right, size: 17, color: palette.muted),
          ],
        ),
      ),
    );
  }
}

/// Horizontal cast list for a short drama: avatar, actor name and role.
///
/// Renders nothing when the series has no cast, so the section disappears
/// rather than leaving an empty heading.
class DetailCastRow extends StatelessWidget {
  final List<CastMember> cast;

  const DetailCastRow({super.key, required this.cast});

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    if (cast.isEmpty) return const SizedBox.shrink();
    final textScaler = MediaQuery.textScalerOf(context);
    final castRowHeight = 118 + (textScaler.scale(12) - 12) * 3;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '演员表',
              style: TextStyle(
                color: palette.ink,
                fontSize: 17,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.2,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${cast.length} 位',
              style: TextStyle(color: palette.muted, fontSize: 12),
            ),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: castRowHeight,
          child: ListView.separated(
            key: const Key('detail_cast_row'),
            scrollDirection: Axis.horizontal,
            itemCount: cast.length,
            separatorBuilder: (context, _) => const SizedBox(width: 14),
            itemBuilder: (context, index) =>
                _CastTile(member: cast[index], palette: palette),
          ),
        ),
      ],
    );
  }
}

class _CastTile extends StatelessWidget {
  final CastMember member;
  final HomePalette palette;

  const _CastTile({required this.member, required this.palette});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: ValueKey(
        'detail_cast_${member.id.isEmpty ? member.actor : member.id}',
      ),
      width: 64,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          ClipOval(
            child: SizedBox.square(
              dimension: 56,
              child: _CastAvatar(member: member, palette: palette),
            ),
          ),
          const SizedBox(height: 7),
          Text(
            member.actor.isEmpty ? '未知' : member.actor,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: palette.ink,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              height: 1.25,
            ),
          ),
          if (member.role.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              '饰 ${member.role}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: palette.muted,
                fontSize: 10.5,
                height: 1.25,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Cast avatars are served as HEIC, which some decoders reject; fall back to the
/// performer's initial so a tile is never blank.
class _CastAvatar extends StatelessWidget {
  final CastMember member;
  final HomePalette palette;

  const _CastAvatar({required this.member, required this.palette});

  @override
  Widget build(BuildContext context) {
    final fallback = _InitialAvatar(member: member, palette: palette);
    if (member.avatar.isEmpty) return fallback;
    return CachedNetworkImage(
      cacheManager: PosterCache.instance,
      imageUrl: member.avatar,
      fit: BoxFit.cover,
      // 56dp avatar; decode at 2×. The cast row scrolls horizontally, so the
      // disk cache that CachedNetworkImage adds over a bare Image.network
      // keeps tiles from being re-downloaded every time they scroll back.
      memCacheWidth: 112,
      placeholder: (context, _) => fallback,
      errorWidget: (context, _, _) => fallback,
    );
  }
}

class _InitialAvatar extends StatelessWidget {
  final CastMember member;
  final HomePalette palette;

  const _InitialAvatar({required this.member, required this.palette});

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: palette.soft,
    child: Center(
      child: Text(
        member.initial,
        style: TextStyle(
          color: palette.muted,
          fontSize: 20,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
  );
}
