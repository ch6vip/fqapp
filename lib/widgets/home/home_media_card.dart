import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../models/media_item.dart';
import '../../services/app_style_tokens.dart';
import '../../services/poster_cache.dart';
import '../cover_tag_chip.dart';
import '../media_card.dart' show mediaLengthLabel;
import 'classic_home_cover_artwork.dart';
import 'home_archive.dart';
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
    final palette = HomePalette.of(context);
    final fallback = AppStyleTokens.of(context).isClassic
        ? CustomPaint(
            painter: ClassicHomeCoverArtwork(item.kind),
            child: Center(
              child: Icon(
                homeKindIcon(item.kind),
                color: Colors.white.withValues(alpha: 0.32),
                size: 38,
              ),
            ),
          )
        : CustomPaint(painter: _CoverArtwork(item));
    final Widget art;
    if (item.cover.isEmpty) {
      art = fallback;
    } else {
      art = CachedNetworkImage(
        cacheManager: PosterCache.instance,
        imageUrl: item.cover,
        fit: fit,
        alignment: alignment,
        memCacheWidth: cacheWidth.clamp(1, 1200),
        fadeInDuration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 120),
        placeholder: (_, _) => fallback,
        errorWidget: (_, _, _) => fallback,
      );
    }
    if (!palette.eink) return art;
    // 墨水屏：封面转灰阶，再压一圈 1dp 黑线（官方墨水屏模式的口径）。
    return ColorFiltered(
      colorFilter: einkCoverFilter,
      child: Stack(
        fit: StackFit.expand,
        children: [
          art,
          IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: Colors.black, width: 1),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 没有封面图时的档案兜底：按媒介取色的渐变 + 竖排衬线书名。
///
/// 旧版是「几何圆环 + 线条图标」，和档案版式的细线、编号不成体系；新版照
/// 搬 mockup 的封面块——书名竖排在左上，底部压一道暗角收边。墨水屏不在这
/// 里另画一套：外层 [einkCoverFilter] 统一转灰度，和 mockup 的
/// `filter: grayscale(1)` 同一口径。
class _CoverArtwork extends CustomPainter {
  _CoverArtwork(this.item);

  final MediaItem item;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final colors = switch (item.kind) {
      'video' => [const Color(0xFF734740), const Color(0xFF242428)],
      'manju' => [const Color(0xFF8B557E), const Color(0xFF35283D)],
      'manga' => [const Color(0xFF6F6887), const Color(0xFF343349)],
      'audio' => [const Color(0xFF426C78), const Color(0xFF233B42)],
      _ => [const Color(0xFF6A7964), const Color(0xFF293C35)],
    };
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          // mockup 的渐变角度是 160deg（略偏右下），不是对角 135deg。
          begin: const Alignment(-0.34, -0.94),
          end: const Alignment(0.34, 0.94),
          colors: colors,
        ).createShader(rect),
    );

    // 竖排书名：左上起排，最多露出封面的 74%，超出的字截断。
    final titleSize = (size.width * 0.13).clamp(12.0, 22.0);
    final style = homeSerifStyle(
      size: titleSize,
      color: const Color(0xEBFFFFFF),
      height: 1.2,
    ).copyWith(letterSpacing: titleSize * 0.12);
    final left = size.width * 0.11;
    final top = size.height * 0.09;
    final limit = top + size.height * 0.74;
    var y = top;
    for (final char in item.title.characters.take(8)) {
      if (y + titleSize * 1.2 > limit) break;
      final glyph = TextPainter(
        text: TextSpan(text: char, style: style),
        textDirection: TextDirection.ltr,
      )..layout();
      glyph.paint(canvas, Offset(left, y));
      y += titleSize * 1.2;
    }

    final scrim = Rect.fromLTWH(
      0,
      size.height * 0.78,
      size.width,
      size.height * 0.22,
    );
    canvas.drawRect(
      scrim,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x00000000), Color(0x2E000000)],
        ).createShader(scrim),
    );
  }

  @override
  bool shouldRepaint(_CoverArtwork oldDelegate) =>
      oldDelegate.item.title != item.title ||
      oldDelegate.item.kind != item.kind;
}

/// The one book card on the shelf.
///
/// 旧版是「白卡 + 阴影 + 评分角标 + 两行简介 + 彩色 chip 行」的模板卡，信息
/// 密度高但每一层都在抢注意力。新版把封面直接铺在画布上、只留三行字：
/// 书名、作者/评分/一句推荐理由。封面自己就是卡片，阴影和描边都不要——
/// 画布是 #F4F3EF，封面的色块已经足够把它和背景分开。
///
/// 简介不进网格：网格负责扫，主视觉负责读。
class HomeMediaCard extends StatelessWidget {
  final MediaItem item;
  final VoidCallback onTap;

  /// Laid-out cell width. The feed already knows it (it sized the grid
  /// delegate with it), and passing it in avoids a [LayoutBuilder] per card.
  final double? coverWidth;

  /// 副标题里带作品长度（「200万字」「共103集」）。首页的推荐卡不需要它，
  /// 搜索结果需要——长度是判断一本书能不能读下去的关键信息。
  final bool showLength;

  /// 封面圆角。首页传入主题 token；其他页面可保留自己的圆角。
  final double radius;

  /// 书名字号。首页 14.5，其他页面保持原来的 15。
  final double titleSize;

  /// 书名下面的一行等宽档案编号；null 或经典主题时连同间距一起移除。
  final String? archiveCode;

  const HomeMediaCard({
    super.key,
    required this.item,
    required this.onTap,
    this.coverWidth,
    this.showLength = false,
    this.radius = 12,
    this.titleSize = 15,
    this.archiveCode,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    final scaler = MediaQuery.textScalerOf(context);
    final meta = _metaText(item, showLength: showLength);
    final archiveCode = AppStyleTokens.of(context).showDecorativeCodes
        ? this.archiveCode
        : null;
    return _CardWidth(
      width: coverWidth,
      builder: (width) => HomePressable(
        onTap: onTap,
        borderRadius: BorderRadius.circular(radius),
        semanticLabel: item.title,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 5 / 7,
              child: RepaintBoundary(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(radius),
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
              height: scaler.scale(titleSize) * 1.35 * 2,
              child: Text(
                item.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: titleSize,
                  height: 1.35,
                  fontWeight: FontWeight.w600,
                  color: palette.ink,
                ),
              ),
            ),
            if (archiveCode != null) ...[
              const SizedBox(height: 5),
              Text(
                archiveCode,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: homeCodeStyle(
                  palette,
                  size: homeCardCodeSize,
                  color: palette.muted,
                ),
              ),
            ],
            if (meta.isNotEmpty) ...[
              SizedBox(height: archiveCode != null ? 2 : 4),
              Text(
                meta,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: homeCardMetaSize,
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
  static String _metaText(MediaItem item, {bool showLength = false}) {
    final score = item.score;
    final length = showLength ? mediaLengthLabel(item) : '';
    return [
      if (item.author.isNotEmpty) item.author,
      if (item.recTags.isNotEmpty) item.recTags.first.text,
      if (length.isNotEmpty) length,
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
