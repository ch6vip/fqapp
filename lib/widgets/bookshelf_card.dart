import 'dart:io';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../models/media_item.dart';
import '../services/poster_cache.dart';
import 'home/home_design.dart';
import 'shelf/shelf_design.dart';

// ---------------------------------------------------------------------------
// Shared pieces.
// ---------------------------------------------------------------------------

/// 封面底图：宽高由调用方按版式给定，圆角与占位逻辑三档共用。
class _ShelfCover extends StatelessWidget {
  final MediaItem item;
  final double width;
  final double height;
  final double radius;
  final String? badgeText;
  final bool selected;

  const _ShelfCover({
    required this.item,
    required this.width,
    required this.height,
    required this.radius,
    this.badgeText,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final fallback = _DefaultCover(item: item);
    return SizedBox(
      key: const Key('bookshelf-cover'),
      width: width,
      height: height,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(radius),
            child: ColoredBox(
              color: palette.soft,
              child: _ShelfCoverImage(
                item: item,
                fallback: fallback,
                width: width,
                height: height,
              ),
            ),
          ),
          // 选中态：accent 18% 蒙层 + 2dp accent 描边（沿用既有视觉）。
          if (selected)
            DecoratedBox(
              decoration: BoxDecoration(
                color: HomePalette.accent.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(radius),
                border: Border.all(color: HomePalette.accent, width: 2),
              ),
            ),
          if (badgeText != null && !selected)
            Positioned(
              top: ShelfTokens.spaceXS,
              right: ShelfTokens.spaceXS,
              child: _ProgressBadge(text: badgeText!),
            ),
        ],
      ),
    );
  }
}

/// 右上角进度角标：accent 渐变小胶囊，贴边内嵌 4dp。
///
/// 角标显示调用方检测到的「更新」或阅读进度。
/// 白字是品牌渐变上的固定前景，允许硬编码。
class _ProgressBadge extends StatelessWidget {
  final String text;

  const _ProgressBadge({required this.text});

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 26),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [HomePalette.accent, Color(0xFFE4432E)],
          ),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
          child: Text(
            text,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.clip,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 9,
              height: 1.2,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

/// 编辑态多选框：22×22dp，选中态填充品牌色。
class _SelectionBox extends StatelessWidget {
  final bool selected;
  final Color border;

  const _SelectionBox({required this.selected, required this.border});

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: 22,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: selected
              ? HomePalette.accent
              : Colors.black.withValues(alpha: 0.18),
          border: Border.all(
            color: selected ? HomePalette.accent : border,
            width: 1.5,
          ),
        ),
        child: selected
            ? const Icon(Icons.check, size: 14, color: Colors.white)
            : null,
      ),
    );
  }
}

class _ShelfCoverImage extends StatelessWidget {
  final MediaItem item;
  final Widget fallback;
  final double width;
  final double height;

  const _ShelfCoverImage({
    required this.item,
    required this.fallback,
    required this.width,
    required this.height,
  });

  @override
  Widget build(BuildContext context) {
    final value = item.cover.trim();
    if (value.isEmpty) return fallback;
    final decodeWidth = math.max(1, (width * 3).round());
    if (_isRemoteCover(value)) {
      return CachedNetworkImage(
        cacheManager: PosterCache.instance,
        imageUrl: value,
        fit: BoxFit.cover,
        memCacheWidth: decodeWidth,
        fadeInDuration: const Duration(milliseconds: 150),
        placeholder: (_, _) => fallback,
        errorWidget: (_, _, _) => fallback,
      );
    }
    final file = _localCoverFile(value);
    if (file == null) return fallback;
    if (file.path.toLowerCase().endsWith('.svg')) {
      return SvgPicture.file(
        file,
        fit: BoxFit.cover,
        placeholderBuilder: (_) => fallback,
      );
    }
    return Image.file(
      file,
      fit: BoxFit.cover,
      cacheWidth: decodeWidth,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) => fallback,
    );
  }
}

bool _isRemoteCover(String value) {
  final lower = value.toLowerCase();
  return lower.startsWith('http://') || lower.startsWith('https://');
}

File? _localCoverFile(String value) {
  final path = value.toLowerCase().startsWith('file://')
      ? Uri.tryParse(value)?.toFilePath() ?? ''
      : value;
  return path.isEmpty ? null : File(path);
}

class _DefaultCover extends StatelessWidget {
  final MediaItem item;

  const _DefaultCover({required this.item});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final palette = HomePalette.of(context);
    final accent = bookshelfKindColor(item.kind) ?? scheme.primary;
    final background = Color.alphaBlend(
      accent.withValues(alpha: 0.14),
      scheme.surfaceContainerHighest,
    );
    final cleaned = _cleanBookInfo(item.title, item.author);
    return LayoutBuilder(
      builder: (context, constraints) => CustomPaint(
        size: Size(constraints.maxWidth, constraints.maxHeight),
        painter: _DefaultCoverPainter(
          background: background,
          accentColor: accent,
          titleColor: palette.ink,
          authorColor: palette.muted,
          title: cleaned.title,
          author: cleaned.author,
        ),
      ),
    );
  }
}

class _CleanedCoverInfo {
  final String title;
  final String author;
  const _CleanedCoverInfo({required this.title, required this.author});
}

/// 智能清洗封面展示的书名与作者：
/// 1. 若标题混入了「作者：xxx」「by xxx」，自动提取出干净作者名，并从书名中剔除；
/// 2. 剥离无意义的打包噪音标签（如 (精校版)、[全本]、(校对版)），还原本真书名。
_CleanedCoverInfo _cleanBookInfo(String rawTitle, String rawAuthor) {
  var title = rawTitle.trim();
  var author = rawAuthor.trim();

  if (author.isEmpty || author == '未知作者') {
    final authorMatch = RegExp(
      r'[（(\[【]?\s*作者\s*[:：\s]+\s*([^）)\]】\s]+)[）)\]】]?',
    ).firstMatch(title);
    if (authorMatch != null) {
      author = authorMatch.group(1)?.trim() ?? '';
      title = title.replaceRange(authorMatch.start, authorMatch.end, '').trim();
    } else {
      final byMatch = RegExp(
        r'[（(\[【]?\s*by\s*[:：\s]+\s*([^）)\]】\s]+)[）)\]】]?',
        caseSensitive: false,
      ).firstMatch(title);
      if (byMatch != null) {
        author = byMatch.group(1)?.trim() ?? '';
        title = title.replaceRange(byMatch.start, byMatch.end, '').trim();
      }
    }
  }

  title = title
      .replaceAll(
        RegExp(
          r'[（(\[【]\s*(?:精校版?|校对版?|全本|全集|完结|完本|精修版?|无错版?|未删节|未删减|手打|更新|排版|精编)[^）)\]】]*[）)\]】]',
        ),
        '',
      )
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  title = title.replaceAll(RegExp(r'^[_\-—\s,，:：]+|[_\-—\s,，:：]+$'), '').trim();
  author = author
      .replaceAll(RegExp(r'^(?:作者|by)[:：\s]*', caseSensitive: false), '')
      .trim();

  if (title.isEmpty) title = rawTitle.trim();
  return _CleanedCoverInfo(title: title, author: author);
}

class _DefaultCoverPainter extends CustomPainter {
  final Color background;
  final Color accentColor;
  final Color titleColor;
  final Color authorColor;
  final String title;
  final String author;

  const _DefaultCoverPainter({
    required this.background,
    required this.accentColor,
    required this.titleColor,
    required this.authorColor,
    required this.title,
    required this.author,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width < 20 || size.height < 30) {
      canvas.drawRect(Offset.zero & size, Paint()..color = background);
      return;
    }

    // 1. 实体封面底色与微渐变光泽
    final bgRect = Offset.zero & size;
    final bgPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Color.alphaBlend(Colors.white.withValues(alpha: 0.08), background),
          background,
          Color.alphaBlend(Colors.black.withValues(alpha: 0.06), background),
        ],
      ).createShader(bgRect);
    canvas.drawRect(bgRect, bgPaint);

    // 2. 左侧物理书脊立体折痕与暗影
    final spineWidth = (size.width * 0.055).clamp(4.0, 7.0);
    final spineRect = Rect.fromLTWH(0, 0, spineWidth, size.height);
    final spinePaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        colors: [
          Colors.black.withValues(alpha: 0.18),
          Colors.black.withValues(alpha: 0.04),
          Colors.transparent,
        ],
      ).createShader(spineRect);
    canvas.drawRect(spineRect, spinePaint);

    // 书脊折痕细线
    canvas.drawLine(
      Offset(spineWidth, 0),
      Offset(spineWidth, size.height),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.12)
        ..strokeWidth = 0.8,
    );

    // 3. 极小缩略图（如列表行 56x78）精简模式
    if (size.width < 70) {
      _paintCompact(canvas, size, spineWidth);
      return;
    }

    // 4. 标准封面：内封装饰雅致边框
    final insetLeft = spineWidth + 5.0;
    const insetTop = 6.0;
    const insetRight = 6.0;
    const insetBottom = 6.0;
    final innerRect = Rect.fromLTRB(
      insetLeft,
      insetTop,
      size.width - insetRight,
      size.height - insetBottom,
    );
    final borderPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8
      ..color = accentColor.withValues(alpha: 0.22);
    canvas.drawRRect(
      RRect.fromRectAndRadius(innerRect, const Radius.circular(3.0)),
      borderPaint,
    );

    // 5. 核心排版区（居中偏上黄金分割位）
    final contentWidth = size.width - spineWidth - 16.0;
    final centerX = spineWidth + 8.0 + contentWidth / 2;

    // 字号根据封面物理宽度与字数动态适配，彻底告别过大散落的巨幅单字
    final double titleFontSize;
    if (size.width < 125) {
      if (title.length <= 5) {
        titleFontSize = 12.5;
      } else if (title.length <= 9) {
        titleFontSize = 11.0;
      } else {
        titleFontSize = 10.0;
      }
    } else {
      if (title.length <= 5) {
        titleFontSize = 14.5;
      } else if (title.length <= 9) {
        titleFontSize = 13.0;
      } else {
        titleFontSize = 11.5;
      }
    }

    final titlePainter = TextPainter(
      text: TextSpan(
        text: title,
        style: TextStyle(
          color: titleColor,
          fontSize: titleFontSize,
          fontWeight: FontWeight.w700,
          height: 1.25,
          letterSpacing: 0.3,
        ),
      ),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
      maxLines: 3,
      ellipsis: '...',
    )..layout(maxWidth: contentWidth);

    TextPainter? authorPainter;
    if (author.isNotEmpty && size.height > 85) {
      final authorFontSize = (titleFontSize * 0.78).clamp(8.0, 10.0);
      final authorText = author.length > 8 ? author.substring(0, 8) : author;
      authorPainter = TextPainter(
        text: TextSpan(
          text: '$authorText 著',
          style: TextStyle(
            color: authorColor.withValues(alpha: 0.85),
            fontSize: authorFontSize,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.2,
          ),
        ),
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '...',
      )..layout(maxWidth: contentWidth);
    }

    final totalTextHeight =
        titlePainter.height +
        (authorPainter != null ? authorPainter.height + 12.0 : 0.0);

    // 垂直视觉中心（封面高度 32% ~ 36% 处）
    final startY = (size.height * 0.33 - totalTextHeight / 2).clamp(
      insetTop + 8.0,
      size.height * 0.45,
    );

    // 绘制柔和宣纸质感书名签底板（Plaque）
    const padH = 6.0;
    const padV = 8.0;
    final plaqueW =
        (math.max(titlePainter.width, authorPainter?.width ?? 0) + padH * 2)
            .clamp(contentWidth * 0.68, contentWidth);
    final plaqueRect = Rect.fromCenter(
      center: Offset(centerX, startY + totalTextHeight / 2),
      width: plaqueW,
      height: totalTextHeight + padV * 2,
    );
    final plaqueRRect = RRect.fromRectAndRadius(
      plaqueRect,
      const Radius.circular(3.5),
    );

    // 书名签微透白底与雅致细描边
    canvas.drawRRect(
      plaqueRRect,
      Paint()..color = Colors.white.withValues(alpha: 0.42),
    );
    canvas.drawRRect(
      plaqueRRect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.6
        ..color = accentColor.withValues(alpha: 0.25),
    );

    // 绘制标题
    final titleOrigin = Offset(centerX - titlePainter.width / 2, startY + padV);
    titlePainter.paint(canvas, titleOrigin);

    var currentY = startY + padV + titlePainter.height;

    // 绘制雅致分割线（— ◆ —）与作者
    if (authorPainter != null) {
      currentY += 5.0;
      const divHalf = 12.0;
      final divPaint = Paint()
        ..color = accentColor.withValues(alpha: 0.35)
        ..strokeWidth = 0.6;
      canvas.drawLine(
        Offset(centerX - divHalf, currentY),
        Offset(centerX - 3.5, currentY),
        divPaint,
      );
      canvas.drawCircle(
        Offset(centerX, currentY),
        1.1,
        divPaint..style = PaintingStyle.fill,
      );
      canvas.drawLine(
        Offset(centerX + 3.5, currentY),
        Offset(centerX + divHalf, currentY),
        divPaint..style = PaintingStyle.stroke,
      );
      currentY += 5.0;

      authorPainter.paint(
        canvas,
        Offset(centerX - authorPainter.width / 2, currentY),
      );
    }

    // 6. 封面底部古典微章（Publisher Tag/Seal）
    final bottomY = size.height - 18.0;
    final stampPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.6
      ..color = accentColor.withValues(alpha: 0.28);
    final stampRect = Rect.fromCenter(
      center: Offset(centerX, bottomY),
      width: 28.0,
      height: 10.0,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(stampRect, const Radius.circular(2.0)),
      stampPaint,
    );
    final stampText = TextPainter(
      text: TextSpan(
        text: '精品',
        style: TextStyle(
          color: accentColor.withValues(alpha: 0.65),
          fontSize: 6.5,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.0,
        ),
      ),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    )..layout();
    stampText.paint(
      canvas,
      Offset(centerX - stampText.width / 2, bottomY - stampText.height / 2),
    );
  }

  void _paintCompact(Canvas canvas, Size size, double spineWidth) {
    final titlePainter = TextPainter(
      text: TextSpan(
        text: title,
        style: TextStyle(
          color: titleColor,
          fontSize: 8.5,
          fontWeight: FontWeight.w700,
          height: 1.2,
        ),
      ),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
      maxLines: 2,
      ellipsis: '...',
    )..layout(maxWidth: size.width - spineWidth - 6.0);

    final origin = Offset(
      spineWidth + (size.width - spineWidth - titlePainter.width) / 2,
      (size.height - titlePainter.height) / 2,
    );
    titlePainter.paint(canvas, origin);
  }

  @override
  bool shouldRepaint(_DefaultCoverPainter oldDelegate) =>
      oldDelegate.background != background ||
      oldDelegate.accentColor != accentColor ||
      oldDelegate.titleColor != titleColor ||
      oldDelegate.authorColor != authorColor ||
      oldDelegate.title != title ||
      oldDelegate.author != author;
}

// ---------------------------------------------------------------------------
// 宫格 / 双列 / 列表 cards.
// ---------------------------------------------------------------------------

/// 宫格条目：满格宽封面（比 1.4）+ 进度角标 + 两行标题 + 一行副信息。
///
/// 按压走 [HomePressable] 弹簧缩放；长按由外层 GestureDetector 承接
/// （[HomePressable] 只暴露 onTap，不为此改动共享的 home 组件）。
class BookshelfGridCard extends StatelessWidget {
  final MediaItem item;
  final String? badgeText;
  final String? infoText;
  final bool editing;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const BookshelfGridCard({
    super.key,
    required this.item,
    required this.onTap,
    this.badgeText,
    this.infoText,
    this.editing = false,
    this.selected = false,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final titleHeight =
        scaler.scale(ShelfTokens.titleGrid) * ShelfTokens.titleLineHeight * 2;
    return Semantics(
      button: true,
      selected: selected,
      label: item.title,
      child: GestureDetector(
        onLongPress: onLongPress,
        child: HomePressable(
          onTap: onTap,
          semanticLabel: item.title,
          borderRadius: BorderRadius.circular(ShelfTokens.radiusCover),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth.isFinite
                  ? constraints.maxWidth
                  : shelfGridCellWidth(360);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Stack(
                    children: [
                      _ShelfCover(
                        item: item,
                        width: width,
                        height: width * ShelfTokens.gridCoverRatio,
                        radius: ShelfTokens.radiusCover,
                        badgeText: editing ? null : badgeText,
                        selected: selected,
                      ),
                      if (editing)
                        Positioned(
                          top: 5,
                          left: 5,
                          child: _SelectionBox(
                            selected: selected,
                            border: Colors.white,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  SizedBox(
                    height: titleHeight,
                    width: double.infinity,
                    child: Text(
                      item.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: ShelfTokens.titleGrid,
                        fontWeight: FontWeight.w500,
                        height: ShelfTokens.titleLineHeight,
                        color: palette.ink,
                      ),
                    ),
                  ),
                  if (infoText != null) ...[
                    const SizedBox(height: ShelfTokens.spaceXS),
                    SizedBox(
                      width: double.infinity,
                      child: Text(
                        infoText!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: ShelfTokens.subtitle,
                          height: ShelfTokens.subtitleLineHeight,
                          color: palette.muted,
                        ),
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// 双列条目：整格是一张卡（surface 底、radius 14、line 描边），上半封面
/// （满格宽减 padding、比 1.4），下半 标题 1 行 + 副信息 1 行 + 类型标签。
///
/// 取消了官方的封面/信息卡 84dp 重叠布局：重叠栈在无障碍大字号下需要手工
/// 对齐两套高度，且信息卡盖住封面下沿的「悬浮」观感在扁平分层语言里收益
/// 不成正比；改成顺排 Column 后几何全部由 token 推导，不会重叠。
class BookshelfDoubleCard extends StatelessWidget {
  final MediaItem item;
  final String? badgeText;
  final String? subtitleText;
  final bool editing;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const BookshelfDoubleCard({
    super.key,
    required this.item,
    required this.onTap,
    this.badgeText,
    this.subtitleText,
    this.editing = false,
    this.selected = false,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final titleHeight =
        scaler.scale(ShelfTokens.titleDouble) * ShelfTokens.titleLineHeight;
    final subtitleHeight =
        scaler.scale(ShelfTokens.subtitle) * ShelfTokens.subtitleLineHeight;
    final kindColor = bookshelfKindColor(item.kind);
    return Semantics(
      button: true,
      selected: selected,
      label: item.title,
      child: GestureDetector(
        onLongPress: onLongPress,
        child: HomePressable(
          onTap: onTap,
          semanticLabel: item.title,
          borderRadius: BorderRadius.circular(ShelfTokens.radiusCard),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final cellWidth = constraints.maxWidth.isFinite
                  ? constraints.maxWidth
                  : 160.0;
              final coverWidth = math.max(
                1.0,
                cellWidth - ShelfTokens.doubleCardPadding * 2,
              );
              final coverHeight = coverWidth * ShelfTokens.doubleCoverRatio;
              final tagHeight = shelfKindTagHeight(context);
              return DecoratedBox(
                key: const Key('shelf-double-card'),
                decoration: BoxDecoration(
                  color: palette.surface,
                  borderRadius: BorderRadius.circular(ShelfTokens.radiusCard),
                  border: Border.all(color: palette.line, width: 0.5),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(ShelfTokens.doubleCardPadding),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Stack(
                        children: [
                          _ShelfCover(
                            item: item,
                            width: coverWidth,
                            height: coverHeight,
                            radius: ShelfTokens.radiusCover,
                            badgeText: editing ? null : badgeText,
                            selected: selected,
                          ),
                          if (editing)
                            Positioned(
                              top: 5,
                              left: 5,
                              child: _SelectionBox(
                                selected: selected,
                                border: Colors.white,
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: ShelfTokens.spaceS),
                      SizedBox(
                        height: titleHeight,
                        width: double.infinity,
                        child: Text(
                          item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: ShelfTokens.titleDouble,
                            fontWeight: FontWeight.w600,
                            height: ShelfTokens.titleLineHeight,
                            color: palette.ink,
                          ),
                        ),
                      ),
                      const SizedBox(height: ShelfTokens.spaceXS),
                      if (subtitleText != null)
                        SizedBox(
                          height: subtitleHeight,
                          width: double.infinity,
                          child: Text(
                            subtitleText!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: ShelfTokens.subtitle,
                              height: ShelfTokens.subtitleLineHeight,
                              color: palette.muted,
                            ),
                          ),
                        ),
                      const SizedBox(height: 6),
                      // 类型小标签：kind 色 12% 底（数据真实存在，非装饰）。
                      SizedBox(
                        height: tagHeight,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: (kindColor ?? palette.muted).withValues(
                              alpha: 0.12,
                            ),
                            borderRadius: BorderRadius.circular(
                              ShelfTokens.kindTagSize,
                            ),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: ShelfTokens.spaceS,
                            ),
                            child: Text(
                              bookshelfKindLabel(item.kind),
                              maxLines: 1,
                              style: TextStyle(
                                fontSize: ShelfTokens.kindTagSize,
                                height: 1.2,
                                fontWeight: FontWeight.w500,
                                color: kindColor ?? palette.muted,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// 列表条目：84dp 行、56×78 封面、标题 + 副信息两行、行底 3dp 进度条。
///
/// 行级用 InkWell 水波而不是弹簧缩放：整行缩放的位移感在密集列表里会抖，
/// 卡片级的缩放只留给宫格/双列。
class BookshelfListCard extends StatelessWidget {
  final MediaItem item;
  final String? progressText;
  final String? metaText;

  /// 阅读进度 0..1；无值时不渲染行底进度条。
  final double? progress;
  final bool editing;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const BookshelfListCard({
    super.key,
    required this.item,
    required this.onTap,
    this.progressText,
    this.metaText,
    this.progress,
    this.editing = false,
    this.selected = false,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Semantics(
      button: true,
      selected: selected,
      label: item.title,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        // 行主体兜底最小高度，进度条占行高最后 3dp：行总高恒为 listRowHeight
        // （无障碍大字号下由内容撑高，不溢出）。这里不能用 Expanded —— ListView
        // 给行的主轴（高度）方向是无界的，flex 子项会直接抛
        // 「non-zero flex but incoming height constraints are unbounded」。
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(
                minHeight:
                    ShelfTokens.listRowHeight -
                    (progress == null ? 0 : ShelfTokens.listProgressHeight),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const SizedBox(width: ShelfTokens.screenPadding),
                  if (editing) ...[
                    _SelectionBox(selected: selected, border: palette.line),
                    const SizedBox(width: ShelfTokens.spaceM),
                  ],
                  _ShelfCover(
                    item: item,
                    width: ShelfTokens.listCoverWidth,
                    height: ShelfTokens.listCoverHeight,
                    radius: ShelfTokens.radiusListCover,
                    selected: selected,
                  ),
                  const SizedBox(width: ShelfTokens.spaceM),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: ShelfTokens.titleList,
                            fontWeight: FontWeight.w600,
                            height: 1.35,
                            color: palette.ink,
                          ),
                        ),
                        if (progressText != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 3),
                            child: Text(
                              progressText!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: ShelfTokens.subtitle,
                                height: ShelfTokens.subtitleLineHeight,
                                color: palette.muted,
                              ),
                            ),
                          ),
                        if (metaText != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 3),
                            child: Text(
                              metaText!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: ShelfTokens.subtitle,
                                height: ShelfTokens.subtitleLineHeight,
                                color: palette.muted,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: ShelfTokens.screenPadding),
                ],
              ),
            ),
            if (progress != null)
              SizedBox(
                key: const Key('shelf-list-progress'),
                height: ShelfTokens.listProgressHeight,
                width: double.infinity,
                child: Stack(
                  children: [
                    ColoredBox(color: palette.line),
                    FractionallySizedBox(
                      widthFactor: progress!.clamp(0, 1),
                      alignment: Alignment.centerLeft,
                      child: const ColoredBox(color: HomePalette.accent),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
