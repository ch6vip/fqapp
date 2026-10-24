import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../models/book_detail.dart';
import '../../models/media_item.dart';
import '../home/home_design.dart';
import '../home/home_media_card.dart';

/// Detail-page masthead: the cover sits on the left with the title, metadata
/// and origin badge stacked to its right, matching the official layout.
///
/// The text does not rebuild per frame. The tinted backdrop lives on the page
/// itself ([DetailMastheadWash]) so the title bar cannot cut it in two.
/// The title deliberately has no `maxLines` so it always wraps in full rather
/// than truncating.
class DetailHero extends StatelessWidget {
  final MediaItem item;
  final BookDetail? detail;

  /// 桌面两栏布局：去掉顶部色块，封面放大并整体居中。
  final bool desktop;
  final bool compactDesktop;

  const DetailHero({
    super.key,
    required this.item,
    this.detail,
    this.desktop = false,
    this.compactDesktop = false,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final meta = detail?.metaParts ?? const <String>[];
    final title = detail?.title.isNotEmpty == true ? detail!.title : item.title;
    // A 3x accessibility scale cannot fit a cover beside the text on a narrow
    // phone, so the masthead stacks instead of squeezing both into one row.
    final stacked = MediaQuery.textScalerOf(context).scale(16) > 26;

    final cover = _CoverTile(
      item: item,
      detail: detail,
      desktop: desktop,
      compact: compactDesktop,
    );
    final info = Column(
      crossAxisAlignment: desktop && !compactDesktop
          ? CrossAxisAlignment.center
          : CrossAxisAlignment.start,
      children: [
        _BookTitle(
          text: title,
          style: TextStyle(
            color: palette.ink,
            fontSize: desktop ? 22 : 20,
            fontWeight: FontWeight.w700,
            height: 1.35,
            letterSpacing: -0.4,
          ),
        ),
        if (meta.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            meta.join(' · '),
            key: const Key('detail_meta_line'),
            style: TextStyle(
              color: palette.muted,
              fontSize: desktop ? 13 : 12.5,
              height: desktop ? 1.6 : 1.4,
            ),
          ),
        ],
        if (detail?.original == true) ...[
          const SizedBox(height: 10),
          const _OriginBadge(),
        ],
      ],
    );

    return ClipRect(
      child: Stack(
        children: [
          // Smooth bottom blend gradient fading seamlessly to canvas
          if (!desktop)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 56,
              child: ExcludeSemantics(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        palette.canvas.withValues(alpha: 0),
                        palette.canvas,
                      ],
                    ),
                  ),
                ),
              ),
            ),
          Padding(
            padding: desktop
                ? const EdgeInsets.fromLTRB(0, 16, 0, 0)
                : const EdgeInsets.fromLTRB(20, 6, 20, 22),
            child: (stacked || (desktop && !compactDesktop))
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
                      const SizedBox(width: 18),
                      Expanded(child: info),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

/// 3:4 cover with a soft shadow, tappable to open the zoomable viewer.
class _CoverTile extends StatelessWidget {
  final MediaItem item;
  final BookDetail? detail;

  /// 桌面两栏布局：封面放大到 168×224。
  final bool desktop;

  final bool compact;
  const _CoverTile({
    required this.item,
    this.detail,
    this.desktop = false,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    // The cover keeps its 3:4 ratio; it only grows a little with text scale so
    // the text column is never starved of width.
    final width =
        (desktop ? (compact ? 112.0 : 168.0) : 104.0) +
        (scaler.scale(16) - 16).clamp(0.0, 10.0) * 1.2;
    return SizedBox(
      width: width,
      child: HomePressable(
        key: const Key('detail_cover_button'),
        semanticLabel: '查看《${item.title}》封面',
        onTap: () => showDetailCover(context, item),
        borderRadius: BorderRadius.circular(12),
        child: ExcludeSemantics(
          child: AspectRatio(
            aspectRatio: 3 / 4,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(
                      alpha: palette.dark ? 0.46 : 0.16,
                    ),
                    blurRadius: 20,
                    spreadRadius: -4,
                    offset: const Offset(2, 9),
                  ),
                  BoxShadow(
                    color: HomePalette.accent.withValues(
                      alpha: palette.dark ? 0.10 : 0.05,
                    ),
                    blurRadius: 14,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    StoryCover(item: item, cacheWidth: 320),
                    Positioned(
                      left: 0,
                      top: 0,
                      bottom: 0,
                      width: 14,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              Colors.black.withValues(alpha: 0.28),
                              Colors.white.withValues(alpha: 0.18),
                              Colors.transparent,
                            ],
                            stops: const [0, 0.32, 1],
                          ),
                        ),
                      ),
                    ),
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: Colors.white.withValues(
                              alpha: palette.dark ? 0.16 : 0.28,
                            ),
                            width: 0.8,
                          ),
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
    );
  }
}

/// `原创` chip shown under the metadata line for original works.
class _OriginBadge extends StatelessWidget {
  const _OriginBadge();

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
      decoration: BoxDecoration(
        color: HomePalette.accent.withValues(alpha: palette.dark ? 0.18 : 0.10),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: HomePalette.accent.withValues(
            alpha: palette.dark ? 0.32 : 0.22,
          ),
          width: 0.6,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.sparkles, size: 11, color: palette.accentText),
          const SizedBox(width: 4),
          Text(
            '原创',
            style: TextStyle(
              color: palette.accentText,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }
}

/// Book title that always shows the complete name. A phrase boundary
/// (`，：`) is preferred over leaving one or two characters on their own line.
class _BookTitle extends StatelessWidget {
  final String text;
  final TextStyle style;

  const _BookTitle({required this.text, required this.style});

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final scaler = MediaQuery.textScalerOf(context);
      final effectiveStyle = DefaultTextStyle.of(context).style.merge(style);
      final painter = TextPainter(
        textDirection: Directionality.of(context),
        textScaler: scaler,
      );
      void measure(String value, [double? width]) {
        painter.text = TextSpan(text: value, style: effectiveStyle);
        painter.layout(maxWidth: width ?? double.infinity);
      }

      measure(text);
      final naturalWidth = painter.width;
      var display = text;
      var width = constraints.maxWidth;
      if (naturalWidth > width &&
          naturalWidth < width * 2 &&
          scaler.scale(1) <= 1.6) {
        var difference = double.infinity;
        for (final match in RegExp('[，,：:]').allMatches(text)) {
          final head = text.substring(0, match.end);
          final tail = text.substring(match.end).trimLeft();
          if (tail.isEmpty) continue;
          measure(head);
          final headWidth = painter.width;
          measure(tail);
          final tailWidth = painter.width;
          final balance = (headWidth - tailWidth).abs();
          if (headWidth <= width &&
              tailWidth <= width &&
              headWidth > naturalWidth * 0.25 &&
              tailWidth > naturalWidth * 0.25 &&
              balance < difference) {
            display = '$head\n$tail';
            difference = balance;
          }
        }
      }
      painter.dispose();
      return ConstrainedBox(
        constraints: BoxConstraints(maxWidth: width),
        child: Text(
          display,
          key: const Key('detail_book_title'),
          semanticsLabel: text,
          style: style,
        ),
      );
    },
  );
}

/// 页面顶部的暖光层。由页面铺在 AppBar 后面，从屏幕最顶端开始淡出，标题
/// 栏就不会再把它截成一条硬边。只跟随滚动轻微上提，不重建正文。
///
/// 渐变只画一次，滚动时只做 [Transform.translate]。若把滚动量塞进
/// painter，每个滚动帧都要重建 shader 并整条重绘，而这张渐变在滚动中
/// 其实从不改变。
///
/// 浅色和深色 / OLED 都保留这层暖光（深色的红色渐变是对的，也是浅色纸面
/// 的参照）；只有墨水屏要纯白画布，不创建 painter。
class DetailMastheadWash extends StatelessWidget {
  final ScrollController scroll;

  const DetailMastheadWash({super.key, required this.scroll});

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    if (palette.eink) return const SizedBox.shrink();
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    return ExcludeSemantics(
      child: IgnorePointer(
        child: LayoutBuilder(
          builder: (context, constraints) => RepaintBoundary(
            key: const Key('detail_masthead_wash'),
            child: Stack(
              clipBehavior: Clip.hardEdge,
              children: [
                Positioned(
                  left: 0,
                  top: 0,
                  right: 0,
                  // 层高多留一截上提的余量，平移后底部不会露出没画的画布。
                  height: constraints.maxHeight + _mastheadLiftMax,
                  child: AnimatedBuilder(
                    animation: scroll,
                    // 画出渐变的那层是 child：滚动只移动它，不重建 painter。
                    child: RepaintBoundary(
                      child: CustomPaint(
                        painter: _MastheadWash(
                          palette: palette,
                          height: constraints.maxHeight,
                        ),
                      ),
                    ),
                    builder: (context, child) => Transform.translate(
                      offset: Offset(
                        0,
                        reducedMotion ? 0 : -_mastheadLift(scroll),
                      ),
                      child: child,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 暖光最多上提这么多：原先把滚动量直接喂给 painter 时也是 240 × 0.22。
const double _mastheadLiftMax = 240 * 0.22;

double _mastheadLift(ScrollController scroll) {
  if (!scroll.hasClients) return 0;
  return scroll.offset.clamp(0.0, 240.0) * 0.22;
}

/// Soft accent wash behind the masthead, fading into the page background.
/// It lifts slightly as the page scrolls, then stops —— 上提由外层
/// [Transform.translate] 完成，这里只画静止的渐变。
///
/// [height] 是它自己的可见高度：多留出来的上提余量不能算进渐变长度，
/// 否则同一条渐变会被拉长，越滚越淡。
///
/// 深色 / OLED 用更强的 alpha，浅色纸面用轻一档的；墨水屏不创建这个 painter
/// （见 [DetailMastheadWash]）。
class _MastheadWash extends CustomPainter {
  final HomePalette palette;
  final double height;

  const _MastheadWash({required this.palette, required this.height});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(0, 0, size.width, height);
    final paint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          HomePalette.accent.withValues(alpha: palette.dark ? 0.17 : 0.10),
          HomePalette.accent.withValues(alpha: palette.dark ? 0.05 : 0.03),
          palette.canvas.withValues(alpha: 0),
        ],
        stops: const [0, 0.5, 1],
      ).createShader(rect);
    canvas.drawRect(rect, paint);
  }

  @override
  bool shouldRepaint(_MastheadWash oldDelegate) =>
      oldDelegate.height != height ||
      oldDelegate.palette.dark != palette.dark ||
      oldDelegate.palette.oled != palette.oled ||
      oldDelegate.palette.canvas != palette.canvas;
}

Future<void> showDetailCover(BuildContext context, MediaItem item) =>
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '关闭封面',
      barrierColor: Colors.black.withValues(alpha: 0.92),
      transitionDuration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 260),
      pageBuilder: (context, animation, secondaryAnimation) => SafeArea(
        child: Material(
          color: Colors.transparent,
          child: Column(
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: IconButton(
                    tooltip: '关闭封面',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(LucideIcons.x, color: Colors.white),
                  ),
                ),
              ),
              Expanded(
                child: InteractiveViewer(
                  key: const Key('detail_cover_viewer'),
                  maxScale: 3,
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 420),
                        child: AspectRatio(
                          aspectRatio: 5 / 7,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: StoryCover(item: item, cacheWidth: 1000),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(28, 20, 28, 28),
                child: Text(
                  item.title,
                  textAlign: TextAlign.center,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    height: 1.5,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
