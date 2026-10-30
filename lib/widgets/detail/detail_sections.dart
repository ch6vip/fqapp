import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../models/series_detail.dart';
import '../../services/poster_cache.dart';
import '../home/home_design.dart';

/// Five stars filled to [stars] (halves supported), used by review tiles.
///
/// Lucide strokes, not the Material star font, so every icon on the detail
/// page shares one family; e-ink keeps the same shapes with palette tokens.
class DetailStarRow extends StatelessWidget {
  final double stars;
  final double size;

  const DetailStarRow({super.key, required this.stars, this.size = 11});

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final filled = palette.eink ? palette.ink : HomePalette.accent;
    final empty = palette.eink ? palette.surface : palette.line;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var index = 1; index <= 5; index++)
          Builder(
            builder: (context) {
              final full = stars >= index;
              final half = !full && stars >= index - 0.5;
              return Icon(
                half ? LucideIcons.star_half : LucideIcons.star,
                size: size,
                color: full || half ? filled : empty,
              );
            },
          ),
      ],
    );
  }
}

/// Genre tags as rounded chips.
class DetailTagChips extends StatelessWidget {
  final List<String> tags;
  final bool desktop;

  const DetailTagChips({super.key, required this.tags, this.desktop = false});

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
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 4),
            decoration: BoxDecoration(
              color: palette.soft,
              borderRadius: BorderRadius.circular(999),
              border: palette.eink ? Border.all(color: palette.line) : null,
            ),
            child: Text(
              tag,
              style: TextStyle(
                color: palette.muted,
                fontSize: desktop ? 13 : 11.5,
                fontWeight: FontWeight.w500,
                height: 1.35,
              ),
            ),
          ),
      ],
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
                fontSize: 15,
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
