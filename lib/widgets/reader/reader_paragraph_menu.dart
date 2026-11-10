// Ported from Wenku8_Flutter (revision ebcd7f1):
//   lib/reader_selection.dart -> _selectionAction / the glass selection bar
//
// fqapp keeps its paragraph/range geometry and existing listening/underline
// actions. The source glass surface exposes local bookmarks and AI feedback;
// narrow viewports scroll the actions without changing the selection anchor.
// Mechanical substitutions: shared Wenku8 controls replace upstream app_ui;
// GlassOverlaySurface is the shared port and uses the reader's Theme.
// Arrow tips are omitted, as in the upstream selection toolbar.
import 'package:flutter/cupertino.dart';

import '../wenku/wenku_ui.dart';

/// What the reader can do with a long-pressed paragraph.
enum ReaderParagraphAction {
  copy,
  listen,
  underline,
  removeUnderline,
  bookmark,
  missedChange,
}

/// Floating action bar for a long-pressed paragraph or a dragged selection.
///
/// Upstream Wenku8 shows its selection actions in a single glass bar with a
/// leading icon and a label. The fqapp reader keeps the same action set it can
/// actually perform: a whole-paragraph selection (long press) gets 从本段听
/// when enabled, plus 复制 / 划线; a dragged character range gets 复制 / 划线.
class ReaderParagraphMenu extends StatelessWidget {
  /// Width reserved for one action in the anchor maths. The item itself is
  /// centred inside this slot so the bar width matches [resolvePosition].
  static const _itemWidth = 100.0;
  static const _itemHeight = 44.0;
  static const _iconSize = 20.0;
  static const _labelSize = 14.0;

  /// Upstream action padding: 12dp horizontal and vertical.
  static const _multiPadding = 6.0;

  /// The bar floats 8dp away from the anchor (upstream `anchorAbove - 8`).
  static const _arrowHeight = 8.0;

  static const _margin = 10.0;

  final bool underlined;
  final bool isDark;

  /// True for a whole-paragraph selection (long press): the bar keeps
  /// 从本段听. A dragged character range drops it — the official selection
  /// toolbar has no listen item either.
  final bool paragraphScoped;
  final bool showListening;
  final bool showBookmark;
  final bool showAi;
  final double? maxWidth;

  /// True when the bar sits below the touched line. Kept because the reader
  /// page's anchor maths decides the flip side; the Wenku8 glass bar has no
  /// arrow tip of its own.
  final bool belowAnchor;

  /// Fired when an item is tapped. The bar is a plain overlay child of the
  /// reader page (the official one is a non-modal PopupWindow), so there is
  /// no route result to pop — the page owns the selection lifecycle.
  final ValueChanged<ReaderParagraphAction> onAction;

  const ReaderParagraphMenu({
    super.key,
    required this.onAction,
    this.underlined = false,
    this.isDark = false,
    this.paragraphScoped = true,
    this.showListening = true,
    this.showBookmark = false,
    this.showAi = false,
    this.maxWidth,
    this.belowAnchor = true,
  });

  /// Number of items the bar will render; the caller sizes the anchor with it.
  static int itemCount({
    required bool underlined,
    required bool paragraphScoped,
    bool showListening = true,
    bool showBookmark = false,
    bool showAi = false,
  }) {
    final base = paragraphScoped ? (showListening ? 3 : 2) : 2;
    return base + (showBookmark ? 1 : 0) + (showAi ? 1 : 0);
  }

  /// Clamped top-left for the bar anchored at [anchor] (window coordinates),
  /// plus which side of the anchor it ended up on.
  ///
  /// [anchor] sits at the selection's last line bottom (plus clearance for
  /// the end caret's dot); [topAnchor] is the selection's first line top.
  /// The flip places the whole bar above [topAnchor], so a tall selection is
  /// never covered by its own bar; without a top anchor the flip falls back to
  /// the anchor point.
  ///
  /// The reader page calls this per build, so the bar never sits on the
  /// system bars or on the reader's own bottom toolbar ([avoidBottom]).
  static (Offset, bool) resolvePosition({
    required Offset anchor,
    Offset? topAnchor,
    required bool paragraphScoped,
    required Size view,
    required EdgeInsets safeArea,
    required bool underlined,
    bool showListening = true,
    bool showBookmark = false,
    bool showAi = false,
    double avoidBottom = 0,
  }) {
    const flipClearance = 10.0;
    final count = itemCount(
      underlined: underlined,
      paragraphScoped: paragraphScoped,
      showListening: showListening,
      showBookmark: showBookmark,
      showAi: showAi,
    );
    final barWidth = (count * _itemWidth + _multiPadding * 2).clamp(
      0.0,
      (view.width - _margin * 2).clamp(0.0, double.infinity),
    );
    final barHeight = _itemHeight + _arrowHeight;

    final minLeft = _margin;
    final maxLeft = (view.width - barWidth - _margin).clamp(
      minLeft,
      double.infinity,
    );
    final left = (anchor.dx - barWidth / 2).clamp(minLeft, maxLeft);

    final minTop = safeArea.top + _margin;
    final bottomLimit = view.height - safeArea.bottom - avoidBottom - _margin;
    final maxTop = (bottomLimit - barHeight).clamp(minTop, double.infinity);
    final belowTop = anchor.dy + _arrowHeight;
    final below = belowTop + barHeight <= bottomLimit;
    final flippedTop =
        (topAnchor?.dy ?? anchor.dy) -
        barHeight -
        _arrowHeight -
        (topAnchor == null ? 0 : flipClearance);
    final top = (below ? belowTop : flippedTop).clamp(minTop, maxTop);
    return (Offset(left, top), below);
  }

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: BoxConstraints(
      maxWidth: maxWidth ?? MediaQuery.sizeOf(context).width - _margin * 2,
    ),
    child: GlassOverlaySurface(
      key: const ValueKey('reader-selection-glass-bar'),
      preserveOptics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: _multiPadding),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (paragraphScoped && showListening)
                _Item(
                  key: const ValueKey('reader-action-listen'),
                  icon: CupertinoIcons.headphones,
                  label: '从本段听',
                  onTap: () => onAction(ReaderParagraphAction.listen),
                ),
              _Item(
                key: const ValueKey('reader-action-copy'),
                icon: CupertinoIcons.doc_on_doc,
                label: '复制',
                onTap: () => onAction(ReaderParagraphAction.copy),
              ),
              if (showBookmark)
                _Item(
                  key: const ValueKey('reader-action-bookmark'),
                  icon: CupertinoIcons.bookmark,
                  label: '书签',
                  onTap: () => onAction(ReaderParagraphAction.bookmark),
                ),
              if (showAi)
                _Item(
                  key: const ValueKey('reader-action-missed'),
                  icon: CupertinoIcons.sparkles,
                  label: '漏改了',
                  onTap: () => onAction(ReaderParagraphAction.missedChange),
                ),
              _Item(
                key: const ValueKey('reader-action-underline'),
                icon: underlined
                    ? CupertinoIcons.delete
                    : CupertinoIcons.pencil,
                label: underlined ? (paragraphScoped ? '取消划线' : '删除划线') : '划线',
                onTap: () => onAction(
                  underlined
                      ? ReaderParagraphAction.removeUnderline
                      : ReaderParagraphAction.underline,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// One icon + label action in the upstream glass bar; the fixed slot keeps the
/// bar width equal to the anchor maths above.
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
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    child: JellyTapSurface(
      onTap: onTap,
      child: SizedBox(
        width: ReaderParagraphMenu._itemWidth,
        height: ReaderParagraphMenu._itemHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ArchiveIcon(icon, size: ReaderParagraphMenu._iconSize),
              const SizedBox(width: 8),
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    label,
                    maxLines: 1,
                    style: const TextStyle(
                      fontSize: ReaderParagraphMenu._labelSize,
                      fontWeight: FontWeight.w600,
                    ),
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
