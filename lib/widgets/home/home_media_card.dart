import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../models/media_item.dart';
import '../../services/poster_cache.dart';
import '../cover_tag_chip.dart';
import 'home_design.dart';

String homeKindLabel(String kind) => switch (kind) {
  'video' => '短剧',
  'manju' => '漫剧',
  'manga' => '漫画',
  'audio' => '听书',
  _ => '小说',
};

IconData homeKindIcon(String kind) => switch (kind) {
  'video' => LucideIcons.clapperboard,
  'manju' => LucideIcons.film,
  'manga' => LucideIcons.image,
  'audio' => LucideIcons.headphones,
  _ => LucideIcons.book_open,
};

/// 评分文案：整数不带小数位（`9.3分` / `9分`）。
String homeScoreText(double score) => score == score.roundToDouble()
    ? '${score.toStringAsFixed(0)}分'
    : '${score.toStringAsFixed(1)}分';

class StoryCover extends StatelessWidget {
  final MediaItem item;
  final int cacheWidth;
  final Alignment alignment;

  /// How the poster fills its box.
  ///
  /// `cover` is the default: the grid cell itself is a tall 5:7 card, so
  /// cropping a little is fine. A desktop feed card is a landscape window
  /// instead — the same 9:16 poster laid out by width overflows several
  /// times, leaving only the top slice visible. Pass [BoxFit.contain] there
  /// so the whole poster fits (letterboxed black, matching the desktop
  /// video's `VideoFit.contain`).
  final BoxFit fit;

  const StoryCover({
    super.key,
    required this.item,
    required this.cacheWidth,
    this.alignment = Alignment.center,
    this.fit = BoxFit.cover,
  });

  @override
  Widget build(BuildContext context) {
    final fallback = CustomPaint(
      painter: _CoverArtwork(item.kind),
      child: Center(
        child: Icon(
          homeKindIcon(item.kind),
          color: Colors.white.withValues(alpha: 0.32),
          size: 38,
        ),
      ),
    );
    if (item.cover.isEmpty) return fallback;
    return CachedNetworkImage(
      cacheManager: PosterCache.instance,
      imageUrl: item.cover,
      fit: fit,
      alignment: alignment,
      memCacheWidth: cacheWidth.clamp(1, 1200),
      fadeInDuration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 220),
      placeholder: (_, _) => fallback,
      errorWidget: (_, _, _) => fallback,
    );
  }
}

/// An original geometric cover is useful even when an upstream image fails.
class _CoverArtwork extends CustomPainter {
  final String kind;

  const _CoverArtwork(this.kind);

  @override
  void paint(Canvas canvas, Size size) {
    final colors = switch (kind) {
      'video' => [const Color(0xFF734740), const Color(0xFF242428)],
      'manju' => [const Color(0xFF8B557E), const Color(0xFF35283D)],
      'manga' => [const Color(0xFF6F6887), const Color(0xFF343349)],
      'audio' => [const Color(0xFF426C78), const Color(0xFF233B42)],
      _ => [const Color(0xFF6A7964), const Color(0xFF293C35)],
    };
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
        ).createShader(Offset.zero & size),
    );
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8
      ..color = const Color(0xFFF2DFC3).withValues(alpha: 0.22);
    final center = Offset(size.width * 0.92, size.height * 0.30);
    for (var i = 0; i < 6; i++) {
      canvas.drawCircle(center, size.width * (0.27 + i * 0.14), line);
    }
    canvas.save();
    canvas.translate(size.width * 0.17, size.height * 0.74);
    canvas.rotate(-math.pi / 5);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, 0, size.width * 1.1, size.height * 0.13),
        const Radius.circular(4),
      ),
      Paint()..color = const Color(0xFFE2C99A).withValues(alpha: 0.13),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_CoverArtwork oldDelegate) => oldDelegate.kind != kind;
}

/// The one book card on the shelf.
///
/// 旧版是「白卡 + 阴影 + 评分角标 + 两行简介 + 彩色 chip 行」的模板卡，信息
/// 密度高但每一层都在抢注意力。新版把封面直接铺在画布上、只留三行字：
/// 书名、作者/评分/一句推荐理由。封面自己就是卡片，阴影和描边都不要——
/// 画布是 #F6F6F6，封面的色块已经足够把它和背景分开。
///
/// 简介不进网格：网格负责扫，主视觉负责读。
class HomeMediaCard extends StatelessWidget {
  final MediaItem item;
  final VoidCallback onTap;

  /// Laid-out cell width. The feed already knows it (it sized the grid
  /// delegate with it), and passing it in avoids a [LayoutBuilder] per card.
  final double? coverWidth;

  const HomeMediaCard({
    super.key,
    required this.item,
    required this.onTap,
    this.coverWidth,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    final scaler = MediaQuery.textScalerOf(context);
    final meta = _metaText(item);
    return _CardWidth(
      width: coverWidth,
      builder: (width) => HomePressable(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        semanticLabel: item.title,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 5 / 7,
              child: RepaintBoundary(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      StoryCover(
                        item: item,
                        cacheWidth: (width * pixelRatio).ceil(),
                      ),
                      // 只有带配色的角标才是促销标签；没有颜色的 tag 是
                      // 搜索结果里的分类文字，不在封面上重复。
                      if (item.tag case final MediaTag tag when tag.hasColors)
                        Positioned(
                          left: 8,
                          top: 8,
                          right: 8,
                          child: Align(
                            alignment: Alignment.topLeft,
                            child: CoverTagChip(
                              key: const Key('home_card_tag'),
                              label: tag.text,
                              colors: tag.colorsFor(dark: palette.dark),
                            ),
                          ),
                        ),
                      if (item.ep.isNotEmpty && isVideoKind(item.kind))
                        Positioned(
                          left: 8,
                          right: 8,
                          bottom: 8,
                          child: Align(
                            alignment: Alignment.bottomRight,
                            child: Text(
                              item.ep,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                height: 1.2,
                                fontWeight: FontWeight.w600,
                                shadows: [
                                  Shadow(
                                    color: Color(0xCC000000),
                                    blurRadius: 2,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: scaler.scale(15) * 1.35 * 2,
              child: Text(
                item.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 15,
                  height: 1.35,
                  fontWeight: FontWeight.w600,
                  color: palette.ink,
                ),
              ),
            ),
            if (meta.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                meta,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  height: 1.3,
                  color: palette.muted,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 作者 · 第一条推荐理由 · 评分。都是 11sp 的一行灰字，不抢书名。
  static String _metaText(MediaItem item) {
    final score = item.score;
    return [
      if (item.author.isNotEmpty) item.author,
      if (item.recTags.isNotEmpty) item.recTags.first.text,
      if (score != null) homeScoreText(score),
      if (item.author.isEmpty &&
          item.recTags.isEmpty &&
          score == null &&
          item.kind != 'book')
        homeKindLabel(item.kind),
    ].join(' · ');
  }
}

/// Hands the child its available width, either measured here or supplied by a
/// caller that already knows it.
class _CardWidth extends StatelessWidget {
  final double? width;
  final Widget Function(double width) builder;

  const _CardWidth({required this.width, required this.builder});

  @override
  Widget build(BuildContext context) {
    final known = width;
    if (known != null) return builder(known);
    return LayoutBuilder(
      builder: (context, constraints) => builder(constraints.maxWidth),
    );
  }
}
