import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../models/audio_extra.dart';
import '../../services/audio_page_theme.dart';
import '../home/home_design.dart';
import 'audio_cover_card.dart';
import 'audio_subtitle_scroller.dart';

/// 真人讲书的书籍行（官方 `bjo.xml`，尺寸取合成样稿）。
///
/// 真人模式不再显示 0.72 屏宽的大封面：48×64 封面 + 本章集名/书名放在
/// 72dp 高的一行里，右侧 ⇋ 打开简介卡。智能朗读模式仍用大封面。
class AudioRealBookRow extends StatelessWidget {
  /// 书籍行总高（样稿）。
  static const double rowHeight = 72;

  /// 封面宽高（样稿；官方 `bjo.xml` 是 48×48，这里按样稿用竖版）。
  static const double coverWidth = 48;
  static const double coverHeight = 64;

  /// 封面 URL；空串时渲染占位图标。
  final String cover;

  /// 当前集标题，16sp w600。
  final String chapterTitle;

  /// 原著书名，14sp muted。真人模式下页面标题可能被主播名占用，所以调用方
  /// 传 [BookDetail.title]；为空时整行不渲染书名。
  final String bookTitle;

  /// 右侧 ⇋：打开简介卡。
  final VoidCallback? onSwap;

  const AudioRealBookRow({
    super.key,
    this.cover = '',
    required this.chapterTitle,
    this.bookTitle = '',
    this.onSwap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = AudioPageThemeScope.of(context);
    return SizedBox(
      height: rowHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: SizedBox(
                key: const Key('audio_real_book_cover'),
                width: coverWidth,
                height: coverHeight,
                child: AudioCoverImage(url: cover),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    chapterTitle,
                    key: const Key('audio_chapter_title'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: theme.ink,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (bookTitle.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      bookTitle,
                      key: const Key('audio_real_book_title'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: theme.muted, fontSize: 14),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            HomePressable(
              key: const Key('audio_real_swap'),
              semanticLabel: '书籍简介',
              onTap: onSwap ?? () {},
              borderRadius: BorderRadius.circular(6),
              child: Container(
                width: 28,
                height: 28,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: theme.card,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Icon(
                  LucideIcons.arrow_right_left,
                  size: 16,
                  color: theme.ink,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 真人讲书页头下方的 238dp 逐句字幕（官方 `bj3.xml` 的 `a49`）。
///
/// 取证（`AudioPlaySubtitleView`）：238dp 高、左右 20dp、`fadingEdgeLength`
/// 24dp；每个条目是 16sp 正文高度加上下各 10dp，16sp 时约 40dp，当前句
/// `setScaleTextSize` 到 20sp 且 `DEFAULT_BOLD`；`setStartLine` 被硬置为 3，
/// 即当前句停在第三行。右下角的 `aro` 是 12sp「展开」，`visibility=gone`，
/// 背景 `cas` 九宫格只在左上、右下各画一个角括号。
class AudioRealSubtitle extends StatelessWidget {
  /// 字幕区高度（官方 `a49`）。
  static const double areaHeight = 238;

  /// 左右外边距（官方 `layout_marginLeft/Right`）。
  static const double horizontalPadding = 20;

  /// 上下渐隐高度（官方 `fadingEdgeLength`）。
  static const double fadeExtent = 24;

  /// 固定行高：16sp 正文 + 上下各 10dp 内边距 ≈ 40dp。
  static const double rowHeight = AudioSubtitleScroller.realRowHeight;

  /// 当前句字号。
  static const double currentFontSize =
      AudioSubtitleScroller.realCurrentFontSize;

  /// 「展开」距右、距底（样稿）。
  static const double expandRight = 20;
  static const double expandBottom = 6;

  final SubtitleTrack track;
  final Duration position;
  final Duration duration;

  /// 字幕数据、时间点、原著章节三者齐备时才显示「展开」。
  final bool showExpand;

  /// 展开态入口；S6 接页内全文，这里允许为空。
  final VoidCallback? onExpand;

  const AudioRealSubtitle({
    super.key,
    required this.track,
    required this.position,
    this.duration = Duration.zero,
    this.showExpand = false,
    this.onExpand,
  });

  @override
  Widget build(BuildContext context) {
    final theme = AudioPageThemeScope.of(context);
    return SizedBox(
      key: const Key('audio_real_subtitle'),
      height: areaHeight,
      child: Stack(
        children: [
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: horizontalPadding,
              ),
              child: track.isEmpty
                  ? Align(
                      alignment: Alignment.topLeft,
                      child: Padding(
                        // 整块有 24dp 渐隐，状态文案避开它。
                        padding: const EdgeInsets.only(top: fadeExtent),
                        child: Text(
                          '本章暂无同步字幕',
                          key: const Key('audio_real_subtitle_status'),
                          style: TextStyle(color: theme.ink, fontSize: 16),
                        ),
                      ),
                    )
                  : ShaderMask(
                      blendMode: BlendMode.dstIn,
                      shaderCallback: (bounds) => LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: const [
                          Color(0x00FFFFFF),
                          Color(0xFFFFFFFF),
                          Color(0xFFFFFFFF),
                          Color(0x00FFFFFF),
                        ],
                        stops: [
                          0,
                          fadeExtent / areaHeight,
                          1 - fadeExtent / areaHeight,
                          1,
                        ],
                      ).createShader(bounds),
                      child: AudioSubtitleScroller(
                        track: track,
                        position: position,
                        duration: duration,
                        viewportHeight: areaHeight,
                        realBook: true,
                        fontSize: 16,
                        // 官方 `setStartLine` 固定为 3：当前句停在第三行。
                        startLine: 3,
                        currentLineKey: const Key(
                          'audio_real_subtitle_current',
                        ),
                      ),
                    ),
            ),
          ),
          if (showExpand)
            Positioned(
              right: expandRight,
              bottom: expandBottom,
              child: _AudioRealExpandTag(onTap: onExpand),
            ),
        ],
      ),
    );
  }
}

/// 右下角「展开」：12sp 文字，左上和右下各一个 6dp 角括号（官方 `cas`）。
class _AudioRealExpandTag extends StatelessWidget {
  final VoidCallback? onTap;

  const _AudioRealExpandTag({this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = AudioPageThemeScope.of(context);
    return HomePressable(
      key: const Key('audio_real_subtitle_expand'),
      semanticLabel: '展开全文',
      onTap: onTap ?? () {},
      borderRadius: BorderRadius.circular(4),
      child: CustomPaint(
        painter: _CornerBracketPainter(color: theme.ink.withValues(alpha: 0.7)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
          child: Text('展开', style: TextStyle(color: theme.ink, fontSize: 12)),
        ),
      ),
    );
  }
}

/// 只描左上、右下两个角，模拟官方 `cas` 九宫格的装饰角。
class _CornerBracketPainter extends CustomPainter {
  final Color color;

  const _CornerBracketPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    const corner = 6.0;
    const inset = 0.5;
    canvas.drawPath(
      Path()
        ..moveTo(inset, corner)
        ..lineTo(inset, inset)
        ..lineTo(corner, inset),
      paint,
    );
    canvas.drawPath(
      Path()
        ..moveTo(size.width - corner, size.height - inset)
        ..lineTo(size.width - inset, size.height - inset)
        ..lineTo(size.width - inset, size.height - corner),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _CornerBracketPainter oldDelegate) =>
      oldDelegate.color != color;
}
