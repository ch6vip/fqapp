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
///   2dp below it, on #FF1C1C1C with #FFFFFFFF text.
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

  /// See `selection/m.java`: 32dp for one item, 10dp for several.
  static const _singlePadding = 32.0;
  static const _multiPadding = 10.0;
  static const _verticalPadding = 4.0;

  /// The arrow is 15x8dp and overlaps the bar by 1dp (`wr.xml`).
  static const _arrowWidth = 15.0;
  static const _arrowHeight = 8.0;

  /// `UiUtils.getRoundRectDrawable(UIKt.getDp(8), color)` in `m.java`.
  static const _radius = 8.0;

  /// `ReaderCommonColor`: #FF1C1C1C on white, #FF303030 on black.
  static const _barColor = Color(0xFF1C1C1C);
  static const _barColorDark = Color(0xFF303030);

  /// `@color/al` — pure white in both themes.
  static const _foreground = Color(0xFFFFFFFF);

  static const _margin = 10.0;

  final bool underlined;
  final bool isDark;

  /// True when the bar renders above the touched line, so its up-arrow points
  /// back down at the paragraph (`wr.xml` keeps both tips and toggles them).
  final bool arrowAbove;

  const ReaderParagraphMenu({
    super.key,
    this.underlined = false,
    this.isDark = false,
    this.arrowAbove = false,
  });

  Color get _background => isDark ? _barColorDark : _barColor;

  /// Number of items the bar will render; the caller sizes the anchor with it.
  static int itemCount({required bool underlined}) => 3;

  /// Shows the bar next to [anchor], on the side of the screen that has room,
  /// the way `m.java#l` positions its PopupWindow.
  static Future<ReaderParagraphAction?> show(
    BuildContext context, {
    required bool underlined,
    required Offset anchor,
    bool isDark = false,
  }) {
    final count = itemCount(underlined: underlined);
    final barWidth =
        count * _itemWidth + (count == 1 ? _singlePadding : _multiPadding) * 2;
    final barHeight = _verticalPadding * 2 + _itemHeight;
    final size = MediaQuery.sizeOf(context);

    final left = (anchor.dx - barWidth / 2).clamp(
      _margin,
      (size.width - barWidth - _margin).clamp(_margin, double.infinity),
    );
    // Below the touched line by default; above it when the bottom is too close.
    // `showAsDropDown(anchor, x, y, 80)` / `(..., 48)` in m.java.
    var top = anchor.dy + _arrowHeight;
    var below = true;
    if (top + barHeight + _margin > size.height) {
      top = anchor.dy - barHeight - _arrowHeight;
      below = false;
    }
    top = top.clamp(
      _margin,
      (size.height - barHeight - _margin).clamp(_margin, double.infinity),
    );

    return showDialog<ReaderParagraphAction>(
      context: context,
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
              arrowAbove: below,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // The arrow sits on whichever side faces the touched line (`m.java` toggles
    // upArrow/downArrow when the popup flips above the anchor).
    return Material(
      color: Colors.transparent,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Arrow(
            pointingUp: true,
            color: _background,
            visible: arrowAbove,
          ),
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
                  onTap: () =>
                      Navigator.pop(context, ReaderParagraphAction.copy),
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
          _Arrow(
            pointingUp: false,
            color: _background,
            visible: !arrowAbove,
          ),
        ],
      ),
    );
  }
}

/// The 15x8dp tip that ties the bar to the touched line (`wr.xml`).
class _Arrow extends StatelessWidget {
  final bool pointingUp;
  final Color color;
  final bool visible;

  const _Arrow({
    required this.pointingUp,
    required this.color,
    required this.visible,
  });

  @override
  Widget build(BuildContext context) => Visibility(
    visible: visible,
    maintainSize: true,
    maintainAnimation: true,
    maintainState: true,
    child: CustomPaint(
      size: const Size(
        ReaderParagraphMenu._arrowWidth,
        ReaderParagraphMenu._arrowHeight,
      ),
      painter: _ArrowPainter(color: color, pointingUp: pointingUp),
    ),
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
