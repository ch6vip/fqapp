import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/reader_preferences.dart';
import 'reader_chapter_layout.dart';
import 'reader_illustration.dart';

class ReaderPagedView extends StatefulWidget {
  final ReaderChapterLayout layout;
  final int pageIndex;
  final bool hasPreviousChapter;
  final bool hasNextChapter;
  final ValueChanged<int> onPageChanged;
  final Future<void> Function(int) onBoundary;
  final VoidCallback onDragStart;
  final ReaderImageProviderFactory? imageProviderFactory;

  /// Page-turn animation; see [ReaderPageTurnStyle]. The widgets for the
  /// boundary pages beyond the chapter (章末 / 上一章) are optional.
  final ReaderPageTurnStyle turnStyle;
  final Color backgroundColor;
  final Widget? endPage;
  final Widget? startPage;

  /// Fired when a turn lands on a chapter boundary page (direction -1 start /
  /// 1 end). The 章末页 is a stop point: the reader stops narration here while
  /// the deferred advance below may still swap chapters.
  final ValueChanged<int>? onBoundaryLanded;

  const ReaderPagedView({
    super.key,
    required this.layout,
    required this.pageIndex,
    required this.hasPreviousChapter,
    required this.hasNextChapter,
    required this.onPageChanged,
    required this.onBoundary,
    required this.onDragStart,
    required this.turnStyle,
    required this.backgroundColor,
    this.endPage,
    this.startPage,
    this.onBoundaryLanded,
    this.imageProviderFactory,
  });

  @override
  State<ReaderPagedView> createState() => ReaderPagedViewState();
}

class ReaderPagedViewState extends State<ReaderPagedView> {
  late PageController _controller = _newController();
  bool _turning = false;
  Timer? _boundaryLandingTimer;
  bool _boundaryPending = false;
  bool _edgeNotified = false;
  double _overscroll = 0;

  double get _viewportWidth => _controller.position.viewportDimension > 0
      ? _controller.position.viewportDimension
      : 1;

  int get _leading => widget.hasPreviousChapter ? 1 : 0;
  int get _itemCount =>
      widget.layout.pages.length +
      _leading +
      (widget.hasNextChapter || widget.endPage != null ? 1 : 0);

  bool get isAtEndPage =>
      _controller.hasClients &&
      (_controller.page ?? _controller.initialPage.toDouble()) >=
          widget.layout.pages.length + _leading - .01;

  PageController _newController() =>
      PageController(initialPage: widget.pageIndex + _leading, keepPage: false);

  @override
  void didUpdateWidget(covariant ReaderPagedView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.layout, widget.layout) ||
        oldWidget.hasPreviousChapter != widget.hasPreviousChapter ||
        oldWidget.hasNextChapter != widget.hasNextChapter) {
      _boundaryLandingTimer?.cancel();
      final oldController = _controller;
      _controller = _newController();
      _turning = false;
      _boundaryPending = false;
      oldController.dispose();
    }
  }

  @override
  void dispose() {
    _boundaryLandingTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  /// Cancels the deferred chapter advance armed when a boundary page lands.
  ///
  /// Any touch on the 章末/章首 page counts as interacting with it, so the
  /// pending auto-advance is dropped instead of firing 600 ms later — e.g. the
  /// 查看本章评论 button would otherwise swap chapters while its sheet is open.
  void cancelBoundaryLanding() => _boundaryLandingTimer?.cancel();

  /// Wraps a boundary page so its first touch cancels the deferred advance.
  Widget _boundaryInteractionGuard(Widget child) => Listener(
    behavior: HitTestBehavior.translucent,
    onPointerDown: (_) => cancelBoundaryLanding(),
    child: child,
  );

  Future<void> turnPage(int direction) async {
    if (_turning || _boundaryPending || !_controller.hasClients) return;
    final current = _controller.page ?? _controller.initialPage.toDouble();
    // A tap during an unfinished drag must not enqueue another page turn.
    if ((current - current.round()).abs() > .01) return;
    final target = current.round() + direction;
    if (target < 0 || target >= _itemCount) {
      await _requestBoundary(direction);
      return;
    }
    final controller = _controller;
    _turning = true;
    try {
      if (widget.turnStyle == ReaderPageTurnStyle.none) {
        controller.jumpToPage(target);
      } else {
        await controller.animateToPage(
          target,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
        );
      }
    } finally {
      if (identical(controller, _controller)) _turning = false;
    }
  }

  /// 听书跟随翻页: lands on the page holding the estimated narration
  /// position. Jumps without animation — the narration keeps moving, an
  /// animated chase would lag behind forever.
  void followProgress(double progress) {
    if (_turning || _boundaryPending || !_controller.hasClients) return;
    final pages = widget.layout.pages.length;
    if (pages == 0) return;
    final target = (progress * pages).floor().clamp(0, pages - 1);
    final current = _controller.page ?? _controller.initialPage.toDouble();
    final targetItem = target + _leading;
    if ((current - targetItem).abs() < 1) return;
    _controller.jumpToPage(targetItem);
  }

  Future<void> _requestBoundary(int direction) async {
    if (_boundaryPending) return;
    // The final chapter's comments page is a stable stop, with no next chapter
    // to request and no text page to bounce back to.
    if (direction > 0 && !widget.hasNextChapter && widget.endPage != null) {
      return;
    }
    setState(() => _boundaryPending = true);
    final layout = widget.layout;
    try {
      await widget.onBoundary(direction);
    } finally {
      if (mounted && identical(layout, widget.layout)) {
        if (_controller.hasClients) {
          _controller.jumpToPage(widget.pageIndex + _leading);
        }
        setState(() => _boundaryPending = false);
      }
    }
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification.depth != 0 ||
        notification.metrics.axis != Axis.horizontal) {
      return false;
    }
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _overscroll = 0;
      _edgeNotified = false;
      widget.onDragStart();
    }
    if (notification is OverscrollNotification &&
        notification.dragDetails != null &&
        !_edgeNotified) {
      _overscroll += notification.overscroll;
      if (_overscroll.abs() > 32) {
        _edgeNotified = true;
        unawaited(_requestBoundary(_overscroll < 0 ? -1 : 1));
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) => Semantics(
    onScrollLeft: () => unawaited(turnPage(1)),
    onScrollRight: () => unawaited(turnPage(-1)),
    child: NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: PageView.builder(
        key: ObjectKey(_controller),
        controller: _controller,
        physics: _boundaryPending
            ? const NeverScrollableScrollPhysics()
            : const ClampingScrollPhysics(
                parent: AlwaysScrollableScrollPhysics(),
              ),
        itemCount: _itemCount,
        onPageChanged: (index) {
          final page = index - _leading;
          if (page < 0 || page >= widget.layout.pages.length) {
            widget.onBoundaryLanded?.call(page < 0 ? -1 : 1);
            // 章末/章首边界页是停靠点: advancing immediately on landing made
            // the boundary buttons untouchable (they flashed for tens of
            // milliseconds before the chapter swapped). The request is
            // deferred briefly instead — the buttons work during the window,
            // and swiping straight through still advances.
            _boundaryLandingTimer?.cancel();
            if (page >= widget.layout.pages.length && !widget.hasNextChapter) {
              return;
            }
            _boundaryLandingTimer = Timer(
              const Duration(milliseconds: 600),
              () {
                if (!mounted || !_controller.hasClients) return;
                // The user flipped away during the window: leave them be.
                // (Compare rounded: the settle may stop a hair short.)
                final current = _controller.page ?? index.toDouble();
                if (current.round() != index) return;
                unawaited(_requestBoundary(page < 0 ? -1 : 1));
              },
            );
            return;
          }
          _boundaryLandingTimer?.cancel();
          widget.onPageChanged(page);
        },
        itemBuilder: (context, index) {
          final page = index - _leading;
          if (page < 0) {
            return _boundaryInteractionGuard(
              widget.startPage ??
                  Center(
                    child: Text(
                      '上一章',
                      style: TextStyle(color: widget.backgroundColor),
                    ),
                  ),
            );
          }
          if (page >= widget.layout.pages.length) {
            return _boundaryInteractionGuard(
              widget.endPage ??
                  Center(
                    child: Text(
                      '下一章',
                      style: TextStyle(color: widget.backgroundColor),
                    ),
                  ),
            );
          }
          Widget content = ReaderPageContent(
            key: ValueKey('reader-text-page-$page'),
            page: widget.layout.pages[page],
            spec: widget.layout.spec,
            imageProviderFactory: widget.imageProviderFactory,
          );
          if (widget.turnStyle == ReaderPageTurnStyle.cover) {
            // 覆盖: the outgoing page stays pinned while the incoming one
            // slides over it. PageView already slides the incoming page in
            // from the right, so only the page *behind* the fractional
            // position is translated to cancel its own slide.
            content = AnimatedBuilder(
              animation: _controller,
              builder: (context, child) {
                var shift = 0.0;
                if (_controller.hasClients &&
                    _controller.position.haveDimensions) {
                  final current = _controller.page;
                  if (current != null) {
                    final delta = current - (page + _leading);
                    if (delta > 0 && delta < 1) {
                      shift = delta * _viewportWidth;
                    }
                  }
                }
                return Transform.translate(
                  offset: Offset(shift, 0),
                  child: child,
                );
              },
              child: ColoredBox(color: widget.backgroundColor, child: content),
            );
          }
          return content;
        },
      ),
    ),
  );
}

class ReaderPageContent extends StatelessWidget {
  final ReaderTextPage page;
  final ReaderLayoutSpec spec;
  final ReaderImageProviderFactory? imageProviderFactory;

  const ReaderPageContent({
    super.key,
    required this.page,
    required this.spec,
    this.imageProviderFactory,
  });

  @override
  Widget build(BuildContext context) {
    final content = SizedBox(
      width: spec.width,
      height: page.height,
      child: Stack(
        children: [
          for (final fragment in page.fragments)
            Positioned(
              top: fragment.top,
              left: 0,
              right: 0,
              height: fragment.height,
              child: fragment.block.isImage
                  ? ReaderBlockContent(
                      block: fragment.block,
                      spec: spec,
                      imageProviderFactory: imageProviderFactory,
                    )
                  : Semantics(
                      label: fragment.text,
                      excludeSemantics: true,
                      child: ClipRect(
                        child: OverflowBox(
                          alignment: Alignment.topLeft,
                          minHeight: fragment.block.height,
                          maxHeight: fragment.block.height,
                          child: Transform.translate(
                            offset: Offset(0, -fragment.sourceTop),
                            child: ReaderBlockText(
                              block: fragment.block,
                              spec: spec,
                            ),
                          ),
                        ),
                      ),
                    ),
            ),
        ],
      ),
    );
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: spec.horizontalPadding,
        vertical: spec.pagePadding,
      ),
      // Very short landscape windows can be smaller than one scaled text line.
      // Keep that line accessible instead of cropping it or dropping text.
      child: page.height > spec.pageHeight + .001
          ? SingleChildScrollView(primary: false, child: content)
          : Align(alignment: Alignment.topLeft, child: content),
    );
  }
}
