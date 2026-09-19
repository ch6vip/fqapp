import 'package:flutter/material.dart';

/// What the reader can do with a long-pressed paragraph.
enum ReaderParagraphAction { copy, listen, underline, removeUnderline }

/// Floating action bar for a long-pressed paragraph, matching the official one.
///
/// The official client builds this from three decompiled pieces:
///
/// * `com/dragon/read/story/impl/feeds/selection/m.java` — a wrap-content
///   `PopupWindow` with an 8dp rounded background, one 15x8dp arrow on the side
///   facing the paragraph, and horizontal padding of 32dp for a single item or
///   10dp for several.
/// * `res/layout/wr.xml` — the root: up arrow, the item row, down arrow.
/// * `res/layout/wt.xml` — one item: 60x48dp, a 24dp icon, then a 10sp label
///   2dp below it, on a #FF303030 (day) / #FF1C1C1C (night) bar with #FFFFFFFF
///   text.
///
/// The official bar offers 从本句听 / 写段评 / 一键生图 / 分享 plus 复制 / 划线 /
/// 查询. 写段评, 一键生图 and 分享 need account-side endpoints  does not
/// have, so this app shows only the actions it can actually perform and keeps
/// the official geometry, colours and label placement.
///
/// Note: 官方长按工具的版式与颜色取自反编译 m.java / wt.xml / wr.xml，见
/// .agents/notes/implemented/feature/2026-09-18-reader-paragraph-actions.md
class ReaderParagraphMenu extends StatelessWidget {
  /// See `res/layout/wt.xml`.
  static const _itemWidth = 60.0;
  static const _itemHeight = 48.0;
  static const _iconSize = 24.0;
  static const _labelTopGap = 2.0;
  static const _labelSize = 10.0;

  /// See `selection/m.java`: it uses 32dp horizontally for a single item and
  /// 10dp once there are several. This bar always carries three items, so the
  /// 32dp case never applies — it is noted here because that constant is what
  /// makes the official bar wider when only one action is available.
  static const _multiPadding = 10.0;
  static const _verticalPadding = 4.0;

  /// The arrow is 15x8dp and overlaps the bar by 1dp (`wr.xml`).
  static const _arrowWidth = 15.0;
  static const _arrowHeight = 8.0;

  /// `UiUtils.getRoundRectDrawable(UIKt.getDp(8), color)` in `m.java`.
  static const _radius = 8.0;

  /// `selection/m.java#o`, confirmed against its smali: the black theme takes
  /// `s7` #FF1C1C1C and the day theme `u_` #FF303030 (the first branch jadx
  /// shows there is dead code, its result is never assigned).
  static const _barColor = Color(0xFF303030);
  static const _barColorDark = Color(0xFF1C1C1C);

  /// `@color/al` — pure white in both themes.
  static const _foreground = Color(0xFFFFFFFF);

  static const _margin = 10.0;

  final bool underlined;
  final bool isDark;

  /// True when the bar sits below the touched line, so its tip points up at the
  /// paragraph (`m.java` shows downArrow instead once the popup flips above).
  final bool belowAnchor;

  const ReaderParagraphMenu({
    super.key,
    this.underlined = false,
    this.isDark = false,
    this.belowAnchor = true,
  });

  Color get _background => isDark ? _barColorDark : _barColor;

  /// Number of items the bar will render; the caller sizes the anchor with it.
  static int itemCount({required bool underlined}) => 3;

  /// Shows the bar next to [anchor], on the side of the screen that has room,
  /// the way `m.java#l` positions its PopupWindow.
  ///
  /// [anchor] is a `globalPosition` from the long press, i.e. window
  /// coordinates. The dialog is deliberately shown with `useSafeArea: false`:
  /// the default wraps the builder in a `SafeArea`, which shifts every
  /// coordinate by the system insets and floats the bar away from the finger.
  /// Insets are applied here instead, so the bar still clears the system bars.
  static Future<ReaderParagraphAction?> show(
    BuildContext context, {
    required bool underlined,
    required Offset anchor,
    bool isDark = false,
    double avoidBottom = 0,
  }) {
    final count = itemCount(underlined: underlined);
    final barWidth = count * _itemWidth + _multiPadding * 2;
    // Only the tip facing the paragraph is laid out, exactly like `m.java`:
    // it calls `UIKt.gone` on the other arrow, which takes no space. Total
    // height is 8 (tip) + 56 (body) = 64dp, the same 64dp `m.java` uses when
    // it offsets the popup above the anchor.
    final barHeight = _verticalPadding * 2 + _itemHeight + _arrowHeight;

    final media = MediaQuery.of(context);
    final view = media.size;
    final safe = media.padding;

    final minLeft = _margin;
    final maxLeft = (view.width - barWidth - _margin).clamp(
      minLeft,
      double.infinity,
    );
    final left = (anchor.dx - barWidth / 2).clamp(minLeft, maxLeft);

    // The widget is [arrow][body] below the line and [body][arrow] above it;
    // `m.java` swaps upArrow for downArrow at the same moment.
    //
    // [avoidBottom] reserves space the bar must not cover — the reader's own
    // bottom toolbar. Without it, a long press near the page foot leaves the
    // bar sitting on that toolbar instead of flipping above the line.
    final minTop = safe.top + _margin;
    final bottomLimit = view.height - safe.bottom - avoidBottom - _margin;
    final maxTop = (bottomLimit - barHeight).clamp(minTop, double.infinity);
    final belowTop = anchor.dy + _arrowHeight;
    final below = belowTop + barHeight <= bottomLimit;
    final top = (below ? belowTop : anchor.dy - barHeight - _arrowHeight).clamp(
      minTop,
      maxTop,
    );

    return showDialog<ReaderParagraphAction>(
      context: context,
      // See above: keep window coordinates exact.
      useSafeArea: false,
      // The official bar floats over the page without dimming it.
      barrierColor: Colors.transparent,
      builder: (context) => Stack(
        children: [
          Positioned(
            left: left,
            top: top,
            child: ReaderParagraphMenu(
              underlined: underlined,
              isDark: isDark,
              belowAnchor: below,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // `m.java` shows upArrow when the popup hangs below the anchor and
        // downArrow once it flips above; the other arrow is gone, so it takes
        // no space and the painted tip always touches the paragraph.
        if (belowAnchor)
          _Arrow(pointingUp: true, color: _background)
        else
          const SizedBox.shrink(),
        Container(
          height: _itemHeight + _verticalPadding * 2,
          padding: const EdgeInsets.symmetric(
            horizontal: _multiPadding,
            vertical: _verticalPadding,
          ),
          decoration: BoxDecoration(
            color: _background,
            borderRadius: BorderRadius.circular(_radius),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _Item(
                key: const ValueKey('reader-action-listen'),
                icon: Icons.headphones_rounded,
                label: '从本段听',
                onTap: () =>
                    Navigator.pop(context, ReaderParagraphAction.listen),
              ),
              _Item(
                key: const ValueKey('reader-action-copy'),
                icon: Icons.copy_rounded,
                label: '复制',
                onTap: () => Navigator.pop(context, ReaderParagraphAction.copy),
              ),
              _Item(
                key: const ValueKey('reader-action-underline'),
                icon: underlined
                    ? Icons.format_color_reset_rounded
                    : Icons.draw_rounded,
                label: underlined ? '取消划线' : '划线',
                onTap: () => Navigator.pop(
                  context,
                  underlined
                      ? ReaderParagraphAction.removeUnderline
                      : ReaderParagraphAction.underline,
                ),
              ),
            ],
          ),
        ),
        if (!belowAnchor)
          _Arrow(pointingUp: false, color: _background)
        else
          const SizedBox.shrink(),
      ],
    ),
  );
}

/// The 15x8dp tip that ties the bar to the touched line (`wr.xml`).
///
/// The caller only builds the arrow that faces the paragraph, mirroring the
/// `UIKt.gone`/`UIKt.visible` swap in `selection/m.java`, so no visibility
/// flag is needed here.
class _Arrow extends StatelessWidget {
  final bool pointingUp;
  final Color color;

  const _Arrow({required this.pointingUp, required this.color});

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: const Size(
      ReaderParagraphMenu._arrowWidth,
      ReaderParagraphMenu._arrowHeight,
    ),
    painter: _ArrowPainter(color: color, pointingUp: pointingUp),
  );
}

class _ArrowPainter extends CustomPainter {
  final Color color;
  final bool pointingUp;

  const _ArrowPainter({required this.color, required this.pointingUp});

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path();
    if (pointingUp) {
      path
        ..moveTo(size.width / 2, 0)
        ..lineTo(size.width, size.height)
        ..lineTo(0, size.height);
    } else {
      path
        ..moveTo(0, 0)
        ..lineTo(size.width, 0)
        ..lineTo(size.width / 2, size.height);
    }
    path.close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_ArrowPainter old) =>
      old.color != color || old.pointingUp != pointingUp;
}

/// One icon-over-label item; geometry from `res/layout/wt.xml`.
class _Item extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _Item({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(8),
    child: SizedBox(
      width: ReaderParagraphMenu._itemWidth,
      height: ReaderParagraphMenu._itemHeight,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: ReaderParagraphMenu._iconSize,
              color: ReaderParagraphMenu._foreground),
          const SizedBox(height: ReaderParagraphMenu._labelTopGap),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.visible,
            style: const TextStyle(
              color: ReaderParagraphMenu._foreground,
              fontSize: ReaderParagraphMenu._labelSize,
              height: 1.0,
            ),
          ),
        ],
      ),
    ),
  );
}
