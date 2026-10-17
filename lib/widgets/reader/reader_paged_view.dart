import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../services/reader_preferences.dart';
import '../../services/reader_underline_store.dart';
import 'reader_chapter_layout.dart';
import 'reader_page_curl.dart';
import 'reader_illustration.dart';
import 'reader_text_selection.dart';

/// One chapter boundary, animated instead of swapped.
///
/// Between chapters the reader rebuilds the whole pagination, so there is no
/// PageView transition to ride on: the surface used to jump straight from the
/// last page of one chapter to the first page of the next. The host captures
/// the page that was on screen here, and the view slides it away while the
/// incoming page (whatever the rebuilt pagination now shows) slides in.
class ReaderChapterTurn {
  /// `1` turns forward, `-1` turns backward.
  final int direction;

  /// The page on screen when the turn started.
  final ReaderTextPage page;
  final ReaderLayoutSpec spec;

  const ReaderChapterTurn({
    required this.direction,
    required this.page,
    required this.spec,
  });
}

class ReaderPagedView extends StatefulWidget {
  final ReaderChapterLayout layout;
  final int pageIndex;
  final bool hasPreviousChapter;
  final bool hasNextChapter;
  final ValueChanged<int> onPageChanged;
  final Future<void> Function(int) onBoundary;
  final VoidCallback onDragStart;
  final ReaderImageProviderFactory? imageProviderFactory;

  /// Long-press target for a text paragraph (复制 / 从本段听 / 划线). The offset is
  /// the touch point in global coordinates, for anchoring the action bar.
  final void Function(ReaderContentBlock block, Offset globalPosition)?
  onParagraphLongPress;

  /// 官方的不抬手拖动: moves and release while the finger stays down after a
  /// long press. Global coordinates.
  final void Function(Offset globalPosition)? onParagraphLongPressMoveUpdate;
  final void Function(Offset globalPosition)? onParagraphLongPressEnd;

  /// Selection plumbing: the shared scope (palette + hit-test registry), the
  /// live selection, and the chapter's saved range underlines. Handles are
  /// floated by the reader page above the whole content, so the paged view
  /// only needs to paint marks and register geometry.
  final ReaderSelectionScope? selectionScope;
  final ReaderTextSelection? selection;
  final List<ReaderRangeUnderline> rangeUnderlines;

  /// The sentence being narrated, in chapter display-text coordinates.
  final (int, int)? narrationRange;

  /// Page-turn animation; see [ReaderPageTurnStyle].
  final ReaderPageTurnStyle turnStyle;

  /// 滑动直翻：开启后 PageView 不跟随手指（无翻页过渡预览/动画），改为检测
  /// 水平滑动越过阈值时直接翻页（见 [_wrapSwipe]）。仅分页模式有意义。
  final bool instantSwipe;

  final Color backgroundColor;

  /// Optional stop after the final chapter only. Between chapters, turning
  /// past the last/first text page requests the next/previous chapter directly.
  // Note: .agents/notes/implemented/bug-fix/2026-10-15-reader-chapter-turn.md
  final Widget? endPage;
  final VoidCallback? onBookEnd;

  /// Non-null while a chapter boundary is being animated; see
  /// [ReaderChapterTurn]. The host sets it when it starts loading the
  /// neighbouring chapter and clears it from [onChapterTurnCompleted].
  final ReaderChapterTurn? chapterTurn;
  final VoidCallback? onChapterTurnCompleted;

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
    this.instantSwipe = false,
    required this.backgroundColor,
    this.endPage,
    this.onBookEnd,
    this.chapterTurn,
    this.onChapterTurnCompleted,
    this.imageProviderFactory,
    this.onParagraphLongPress,
    this.onParagraphLongPressMoveUpdate,
    this.onParagraphLongPressEnd,
    this.selectionScope,
    this.selection,
    this.rangeUnderlines = const [],
    this.narrationRange,
  });

  @override
  State<ReaderPagedView> createState() => ReaderPagedViewState();
}

/// One in-chapter curl turn: the pages the peel travels between. The
/// progress lives on [_curlAnimation] (animated turns) or is written to it
/// directly (drag turns), and the overlay reads it through [_curlCurved].
class _CurlTurn {
  final int direction;
  final int fromIndex;
  final int toIndex;

  const _CurlTurn({
    required this.direction,
    required this.fromIndex,
    required this.toIndex,
  });
}

class ReaderPagedViewState extends State<ReaderPagedView>
    with TickerProviderStateMixin {
  late PageController _controller = _newController();
  bool _turning = false;
  bool _boundaryPending = false;
  bool _edgeNotified = false;
  double _overscroll = 0;
  int? _dragStartItem;
  double _swipeStartDx = 0;
  double _swipeLastDx = 0;
  Drag? _pageDrag;
  int _pageDragFrom = 0;
  int? _pageDragDirection;

  bool get _followsFinger =>
      !widget.instantSwipe &&
      (widget.turnStyle == ReaderPageTurnStyle.slide ||
          widget.turnStyle == ReaderPageTurnStyle.cover);

  /// Drives the chapter-boundary slide. Short and not interruptible: the host
  /// commits the chapter switch when it finishes.
  late final AnimationController _chapterTurnAnimation;

  /// Drives the 仿真卷页 turn. Point/keys/auto-turn animate it 0 -> 1;
  /// a drag writes the finger position into it directly and releases with
  /// animateTo. The curved view is what the overlay paints.
  late final AnimationController _curlAnimation;
  late final CurvedAnimation _curlCurved;
  _CurlTurn? _curlTurn;
  bool _curlDragging = false;
  double _curlDragStartDx = 0;
  double _curlDragLastDx = 0;
  bool _curlDragLocked = false;
  int? _curlDragEdge;

  bool get _animatesChapterTurn =>
      widget.chapterTurn != null &&
      widget.turnStyle != ReaderPageTurnStyle.none;

  @override
  void initState() {
    super.initState();
    _chapterTurnAnimation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    )..addStatusListener(_onChapterTurnStatus);
    _curlAnimation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _curlCurved = CurvedAnimation(
      parent: _curlAnimation,
      curve: Curves.easeOutCubic,
    )..addStatusListener(_onCurlStatus);

    // The chapter load swaps the whole content subtree, so a boundary turn
    // usually arrives as a fresh mount and never reaches didUpdateWidget.
    if (_animatesChapterTurn) {
      _chapterTurnAnimation.forward(from: 0);
    } else if (widget.chapterTurn != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_animatesChapterTurn) {
          widget.onChapterTurnCompleted?.call();
        }
      });
    }
  }

  void _onChapterTurnStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      widget.onChapterTurnCompleted?.call();
    }
  }

  /// Ends an animated curl turn. The status listener runs before the
  /// `forward`/`animateTo` future completes, so by the time [turnPage]
  /// resumes the pager has already jumped and the overlay is gone.
  void _onCurlStatus(AnimationStatus status) {
    final turn = _curlTurn;
    if (turn == null || _curlDragging) return;
    if (status == AnimationStatus.completed) {
      _controller.jumpToPage(turn.toIndex);
    }
    if (status == AnimationStatus.completed ||
        status == AnimationStatus.dismissed) {
      // Completed: the jump already tells the host to rebuild; dismissed is
      // a cancelled drag curl settling back to 0, where nothing else
      // rebuilds, so the overlay is dropped here.
      _curlTurn = null;
      _turning = false;
      if (mounted) setState(() {});
    }
  }

  /// The controller can be briefly attached to two PageViews during a
  /// chapter-cross rebuild (the old pager unmounts while the new one
  /// mounts). [ScrollController.position] and [PageController.page] assert
  /// a single client, so every read below goes through [positions].
  ScrollPosition? get _attachedPosition {
    for (final position in _controller.positions) {
      if (position.haveDimensions) return position;
    }
    return _controller.positions.firstOrNull;
  }

  double? get _attachedPage {
    final position = _attachedPosition;
    if (position == null || !position.haveDimensions) return null;
    return position.pixels / position.viewportDimension;
  }

  double get _viewportWidth {
    final width = _attachedPosition?.viewportDimension ?? 0;
    return width > 0 ? width : 1;
  }

  bool get _hasEndPage => !widget.hasNextChapter && widget.endPage != null;
  int get _itemCount => widget.layout.pages.length + (_hasEndPage ? 1 : 0);

  bool get isAtEndPage =>
      _controller.hasClients &&
      (_attachedPage ?? _controller.initialPage.toDouble()) >=
          widget.layout.pages.length - .01;

  PageController _newController() =>
      PageController(initialPage: widget.pageIndex, keepPage: false);

  @override
  void didUpdateWidget(covariant ReaderPagedView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.layout, widget.layout) ||
        oldWidget.hasPreviousChapter != widget.hasPreviousChapter ||
        oldWidget.hasNextChapter != widget.hasNextChapter ||
        (oldWidget.endPage == null) != (widget.endPage == null)) {
      _cancelPageDrag();
      final oldController = _controller;
      _controller = _newController();
      _turning = false;
      _boundaryPending = false;
      _dragStartItem = null;
      // A chapter rebuild invalidates the curl overlay's pages.
      _curlTurn = null;
      _curlDragging = false;
      _curlAnimation.reset();
      oldController.dispose();
    }

    // Start the boundary slide as soon as the host hands over the outgoing
    // page; the host commits the chapter switch when it finishes.
    if (_animatesChapterTurn && oldWidget.chapterTurn == null) {
      _chapterTurnAnimation.forward(from: 0);
    } else if (widget.chapterTurn == null) {
      _chapterTurnAnimation.value = 0;
    } else if (oldWidget.chapterTurn == null) {
      // turnStyle is `none`: nothing is painted, so the host must not wait.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_animatesChapterTurn) {
          widget.onChapterTurnCompleted?.call();
        }
      });
    }
  }

  @override
  void dispose() {
    _cancelPageDrag();
    _chapterTurnAnimation.dispose();
    _curlAnimation.dispose();
    _controller.dispose();
    super.dispose();
  }

  Future<void> turnPage(int direction) async {
    if (_turning ||
        _boundaryPending ||
        _pageDrag != null ||
        !_controller.hasClients) {
      return;
    }
    final current = _attachedPage ?? _controller.initialPage.toDouble();
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
      } else if (widget.turnStyle == ReaderPageTurnStyle.curl) {
        // 卷页：PageView 本身不滑动，覆盖层把去页卷到目标页上；动画跑完
        // 时状态回调完成跳页与清理。
        setState(() {
          _curlTurn = _CurlTurn(
            direction: direction,
            fromIndex: current.round(),
            toIndex: target,
          );
        });
        await _curlAnimation.forward(from: 0);
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
    final current = _attachedPage ?? _controller.initialPage.toDouble();
    if ((current - target).abs() < 1) return;
    _controller.jumpToPage(target);
  }

  Future<void> _requestBoundary(int direction) async {
    if (_boundaryPending) return;
    // The final chapter's comments page is a stable stop, with no next chapter
    // to request and no text page to bounce back to.
    if (direction > 0 && _hasEndPage) {
      return;
    }
    setState(() => _boundaryPending = true);
    final layout = widget.layout;
    try {
      await widget.onBoundary(direction);
    } finally {
      if (mounted && identical(layout, widget.layout)) {
        if (_controller.hasClients) {
          _controller.jumpToPage(widget.pageIndex);
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
      _dragStartItem = _controller.hasClients
          ? _attachedPage?.round()
          : null;
      widget.onDragStart();
    }
    if (notification is OverscrollNotification &&
        notification.dragDetails != null &&
        !_edgeNotified) {
      // A gesture starting on another text page may reach the edge, but must
      // not also skip that page and cross a chapter within the same swipe.
      final direction = notification.overscroll < 0 ? -1 : 1;
      if (_dragStartItem != (direction < 0 ? 0 : _itemCount - 1)) return false;
      _overscroll += notification.overscroll;
      if (_overscroll.abs() > 32) {
        _edgeNotified = true;
        unawaited(_requestBoundary(_overscroll < 0 ? -1 : 1));
      }
    }
    return false;
  }

  void _cancelPageDrag() {
    _pageDrag?.cancel();
    _pageDrag = null;
  }

  Widget _wrapPageDrag(Widget child) {
    if (!_followsFinger) return child;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      dragStartBehavior: DragStartBehavior.down,
      onHorizontalDragStart: (details) {
        if (_turning || _boundaryPending) return;
        final position = _attachedPosition;
        if (position == null || !position.haveDimensions) return;
        _pageDragFrom = _attachedPage!.round();
        _pageDragDirection = null;
        _pageDrag = position.drag(details, () => _pageDrag = null);
      },
      onHorizontalDragUpdate: (details) {
        final drag = _pageDrag;
        final position = _attachedPosition;
        if (drag == null || position == null) return;
        final delta = details.primaryDelta ?? 0;
        if (delta == 0) return;
        final direction = _pageDragDirection ??= delta < 0 ? 1 : -1;
        final target = _pageDragFrom + direction;
        if (target < 0 || target >= _itemCount) {
          drag.update(details);
          return;
        }
        // Anchor the seam to the finger in the stationary viewport, including
        // when the finger reverses direction before release.
        final width = position.viewportDimension;
        final pixels =
            (_pageDragFrom + (direction > 0 ? 1 : 0)) * width -
            details.localPosition.dx.clamp(0.0, width);
        final offset = position.pixels - pixels;
        drag.update(
          DragUpdateDetails(
            sourceTimeStamp: details.sourceTimeStamp,
            delta: Offset(offset, 0),
            primaryDelta: offset,
            globalPosition: details.globalPosition,
            localPosition: details.localPosition,
          ),
        );
      },
      onHorizontalDragEnd: (details) {
        final page = _attachedPage;
        final direction = _pageDragDirection;
        final velocity = details.primaryVelocity ?? 0;
        if (page != null && direction != null) {
          final first = _pageDragFrom + (direction < 0 ? -1 : 0);
          final last = _pageDragFrom + (direction > 0 ? 1 : 0);
          // Reaching the edge already completes the turn; inertia must not
          // advance beyond the two pages held by this gesture.
          if ((velocity < 0 && page >= last) ||
              (velocity > 0 && page <= first)) {
            details = DragEndDetails(primaryVelocity: 0);
          }
        }
        _pageDrag?.end(details);
        _pageDrag = null;
      },
      onHorizontalDragCancel: _cancelPageDrag,
      child: child,
    );
  }

  /// 滑动直翻：把页面内容包一层水平拖拽识别。越过阈值（屏宽 20%）时直接
  /// 翻页，不显示 PageView 的滑动预览/动画。它位于页面内容（PageView 子节点）
  /// 之上，比 PageView 自身的拖拽识别器更深，从而在手势竞技场中获胜。
  Widget _wrapSwipe(Widget child) {
    if (!widget.instantSwipe) return child;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragStart: (details) {
        _swipeStartDx = details.globalPosition.dx;
        _swipeLastDx = details.globalPosition.dx;
      },
      onHorizontalDragUpdate: (details) {
        _swipeLastDx = details.globalPosition.dx;
      },
      onHorizontalDragEnd: (_) {
        final delta = _swipeLastDx - _swipeStartDx;
        final threshold = MediaQuery.sizeOf(context).width * 0.2;
        if (delta.abs() > threshold) {
          unawaited(turnPage(delta < 0 ? 1 : -1));
        }
      },
      child: child,
    );
  }

  /// 拖拽卷页：把页面内容包一层水平拖拽识别，与 [_wrapSwipe] 同理位于
  /// PageView 子节点之上。方向锁定后把手指位置写进 [_curlAnimation]，
  /// 覆盖层跟手卷；松手超过阈值或甩出速度则翻完，否则卷回。
  Widget _wrapCurl(Widget child) {
    if (widget.turnStyle != ReaderPageTurnStyle.curl) return child;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragStart: (details) {
        if (_turning || _boundaryPending) return;
        _curlDragStartDx = details.globalPosition.dx;
        _curlDragLastDx = details.globalPosition.dx;
        _curlDragLocked = false;
        _curlDragEdge = null;
      },
      onHorizontalDragUpdate: (details) {
        if (_boundaryPending) return;
        // 动画中的点按卷页不接受拖拽转向。
        if (_curlTurn != null && !_curlDragging) return;
        final dx = details.globalPosition.dx;
        _curlDragLastDx = dx;
        final delta = dx - _curlDragStartDx;
        if (!_curlDragLocked) {
          if (delta.abs() < 6) return;
          final direction = delta < 0 ? 1 : -1;
          final current =
              (_attachedPage ?? widget.pageIndex.toDouble()).round();
          final target = current + direction;
          _curlDragLocked = true;
          if (target < 0 || target >= _itemCount) {
            // 章节边缘：不卷页，松手够远时走章节边界。
            _curlDragEdge = direction;
            widget.onDragStart();
            return;
          }
          _curlDragging = true;
          _turning = true;
          setState(() {
            _curlTurn = _CurlTurn(
              direction: direction,
              fromIndex: current,
              toIndex: target,
            );
          });
          widget.onDragStart();
        }
        if (_curlTurn == null) return;
        final width = MediaQuery.sizeOf(context).width;
        _curlAnimation.value =
            (delta.abs() / width).clamp(0.0, 1.0);
      },
      onHorizontalDragEnd: (details) {
        final edge = _curlDragEdge;
        _curlDragEdge = null;
        if (edge != null) {
          final delta = _curlDragLastDx - _curlDragStartDx;
          if (delta.abs() > 32) unawaited(_requestBoundary(edge));
          return;
        }
        final turn = _curlTurn;
        if (turn == null || !_curlDragging) return;
        _curlDragging = false;
        final velocity = details.velocity.pixelsPerSecond.dx;
        final fling = velocity * turn.direction < -400;
        final progress = _curlCurved.value;
        final complete = progress > 0.35 || fling;
        final remaining = complete ? 1 - progress : progress;
        final duration = Duration(
          milliseconds: (remaining * 300).round().clamp(60, 300),
        );
        unawaited(
          _curlAnimation.animateTo(complete ? 1 : 0, duration: duration),
        );
      },
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final turn = widget.chapterTurn;
    Widget pager = _wrapPageDrag(_buildPager());
    // 章节内卷页覆盖层：IgnorePointer，不拦截跟手拖拽；覆盖层内的
    // AnimatedBuilder 只重建卷页子树，不重建整个 PageView。
    if (_curlTurn != null) {
      pager = Stack(
        fit: StackFit.expand,
        children: [
          pager,
          Positioned.fill(
            child: IgnorePointer(child: _buildCurlOverlay()),
          ),
        ],
      );
    }
    if (turn == null || !_animatesChapterTurn) {
      return pager;
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        pager,
        Positioned.fill(
          child: IgnorePointer(child: _buildChapterTurnOverlay(turn)),
        ),
      ],
    );
  }

  /// 章节内卷页的覆盖层：去页卷到目标页上。
  Widget _buildCurlOverlay() {
    final turn = _curlTurn;
    if (turn == null) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: _curlCurved,
      builder: (context, _) => ReaderPageCurl(
        outgoing: _pageWidget(turn.fromIndex),
        incoming: _pageWidget(turn.toIndex),
        progress: _curlCurved.value,
        forward: turn.direction >= 0,
        backgroundColor: widget.backgroundColor,
      ),
    );
  }

  /// 覆盖层里的一页：正文页用无手势的 [ReaderPageContent]，末尾评论页
  /// 直接用 host 的 endPage。
  Widget _pageWidget(int index) {
    final pages = widget.layout.pages;
    if (index >= pages.length) {
      return widget.endPage ?? const SizedBox.shrink();
    }
    return ReaderPageContent(
      page: pages[index],
      spec: widget.layout.spec,
      imageProviderFactory: widget.imageProviderFactory,
    );
  }

  Widget _buildPager() => Semantics(
    onScrollLeft: () => unawaited(turnPage(1)),
    onScrollRight: () => unawaited(turnPage(-1)),
    child: NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: PageView.builder(
        key: ObjectKey(_controller),
        controller: _controller,
        physics:
            (_boundaryPending ||
                widget.instantSwipe ||
                _followsFinger ||
                widget.turnStyle == ReaderPageTurnStyle.curl)
            ? const NeverScrollableScrollPhysics(
                parent: ClampingScrollPhysics(),
              )
            : const ClampingScrollPhysics(
                parent: AlwaysScrollableScrollPhysics(),
              ),
        itemCount: _itemCount,
        onPageChanged: (index) {
          if (index >= widget.layout.pages.length) {
            widget.onBookEnd?.call();
            return;
          }
          widget.onPageChanged(index);
        },
        itemBuilder: (context, index) {
          final page = index;
          if (page >= widget.layout.pages.length) {
            return widget.endPage!;
          }
          Widget content = ReaderPageContent(
            key: ValueKey('reader-text-page-$page'),
            page: widget.layout.pages[page],
            spec: widget.layout.spec,
            imageProviderFactory: widget.imageProviderFactory,
            // Paged mode has to forward this too: without it the inner
            // GestureDetector has a null onLongPress and a long press does
            // nothing at all — which is exactly how 翻页 readers saw it, since
            // scroll mode was the only path that passed it down.
            onParagraphLongPress: widget.onParagraphLongPress,
            onParagraphLongPressMoveUpdate:
                widget.onParagraphLongPressMoveUpdate,
            onParagraphLongPressEnd: widget.onParagraphLongPressEnd,
            selectionScope: widget.selectionScope,
            selection: widget.selection,
            rangeUnderlines: widget.rangeUnderlines,
            narrationRange: widget.narrationRange,
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
                final current = _attachedPage;
                if (current != null) {
                  final delta = current - page;
                  if (delta > 0 && delta < 1) {
                    shift = delta * _viewportWidth;
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
          return _wrapCurl(_wrapSwipe(content));
        },
      ),
    ),
  );

  /// Paints the animated chapter boundary: the outgoing page slides away while
  /// the incoming page — whatever the rebuilt pagination now shows — slides in.
  ///
  /// Both pages are painted here instead of by the PageView because the turn
  /// crosses a rebuild: the pager underneath has already been re-created for
  /// the new chapter, so only an overlay can show both chapters at once.
  Widget _buildChapterTurnOverlay(ReaderChapterTurn turn) {
    final layout = widget.layout;
    final pages = layout.pages;
    if (pages.isEmpty) return const SizedBox.shrink();
    final incoming = pages[widget.pageIndex.clamp(0, pages.length - 1)];
    final forward = turn.direction >= 0;
    // 卷页：章节边界也卷过去，与章节内翻页一致。
    if (widget.turnStyle == ReaderPageTurnStyle.curl) {
      return AnimatedBuilder(
        animation: _chapterTurnAnimation,
        builder: (context, _) => ReaderPageCurl(
          outgoing: _buildTurnPage(turn.page, turn.spec),
          incoming: _buildTurnPage(incoming, layout.spec),
          progress: Curves.easeOutCubic.transform(
            _chapterTurnAnimation.value,
          ),
          forward: forward,
          backgroundColor: widget.backgroundColor,
        ),
      );
    }
    // 覆盖 keeps the outgoing page pinned and slides the new one over it;
    // the slide style moves both.
    final cover = widget.turnStyle == ReaderPageTurnStyle.cover;
    return AnimatedBuilder(
      animation: _chapterTurnAnimation,
      builder: (context, _) {
        final t = Curves.easeOutCubic.transform(_chapterTurnAnimation.value);
        final width =
            (_attachedPosition?.hasContentDimensions ?? false)
            ? _viewportWidth
            : MediaQuery.sizeOf(context).width;
        final outgoingShift = cover ? 0.0 : (forward ? -width * t : width * t);
        final incomingShift = (forward ? 1 - t : t - 1) * width;
        return Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: widget.backgroundColor),
            Transform.translate(
              offset: Offset(outgoingShift, 0),
              child: _buildTurnPage(turn.page, turn.spec),
            ),
            Transform.translate(
              offset: Offset(incomingShift, 0),
              child: _buildTurnPage(incoming, layout.spec),
            ),
          ],
        );
      },
    );
  }

  Widget _buildTurnPage(ReaderTextPage page, ReaderLayoutSpec spec) =>
      ColoredBox(
        color: widget.backgroundColor,
        child: ReaderPageContent(
          page: page,
          spec: spec,
          imageProviderFactory: widget.imageProviderFactory,
        ),
      );
}

class ReaderPageContent extends StatelessWidget {
  final ReaderTextPage page;
  final ReaderLayoutSpec spec;
  final ReaderImageProviderFactory? imageProviderFactory;
  final void Function(ReaderContentBlock block, Offset globalPosition)?
  onParagraphLongPress;
  final void Function(Offset globalPosition)? onParagraphLongPressMoveUpdate;
  final void Function(Offset globalPosition)? onParagraphLongPressEnd;
  final ReaderSelectionScope? selectionScope;
  final ReaderTextSelection? selection;
  final List<ReaderRangeUnderline> rangeUnderlines;
  final (int, int)? narrationRange;

  const ReaderPageContent({
    super.key,
    required this.page,
    required this.spec,
    this.imageProviderFactory,
    this.onParagraphLongPress,
    this.onParagraphLongPressMoveUpdate,
    this.onParagraphLongPressEnd,
    this.selectionScope,
    this.selection,
    this.rangeUnderlines = const [],
    this.narrationRange,
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
              child: Builder(
                builder: (context) {
                  // Marks ride inside the block's own coordinate space (the
                  // OverflowBox child under the -sourceTop shift), so wash and
                  // underlines translate with the fragment and clip at its
                  // bounds; the window tells the hit-test registry which
                  // lines this page shows.
                  final text = ReaderBlockText(
                    block: fragment.block,
                    spec: spec,
                  );
                  final marked =
                      selectionScope != null &&
                          !fragment.block.isTitle &&
                          !fragment.block.isImage &&
                          fragment.block.lines.isNotEmpty
                      ? ReaderBlockMarkLayer(
                          key: ValueKey(
                            'reader-block-marks-${fragment.block.index}',
                          ),
                          block: fragment.block,
                          spec: spec,
                          scope: selectionScope!,
                          selection: selection,
                          rangeUnderlines: rangeUnderlines,
                          narrationRange: narrationRange,
                          windowTop: fragment.sourceTop,
                          windowBottom: fragment.sourceTop + fragment.height,
                          child: text,
                        )
                      : text;
                  final body = ClipRect(
                    child: OverflowBox(
                      alignment: Alignment.topLeft,
                      minHeight: fragment.block.height,
                      maxHeight: fragment.block.height,
                      child: Transform.translate(
                        offset: Offset(0, -fragment.sourceTop),
                        child: marked,
                      ),
                    ),
                  );
                  return fragment.block.isImage
                      ? ReaderBlockContent(
                          block: fragment.block,
                          spec: spec,
                          imageProviderFactory: imageProviderFactory,
                        )
                      : Semantics(
                          label: fragment.text,
                          excludeSemantics: true,
                          child: GestureDetector(
                            // Same key the scroll list uses, so both page modes
                            // expose one stable paragraph target.
                            key: ValueKey(
                              'reader-paragraph-press-${fragment.block.index - 1}',
                            ),
                            behavior: HitTestBehavior.translucent,
                            onLongPressStart: onParagraphLongPress == null
                                ? null
                                : (details) => onParagraphLongPress!(
                                    fragment.block,
                                    details.globalPosition,
                                  ),
                            onLongPressMoveUpdate:
                                onParagraphLongPressMoveUpdate == null
                                ? null
                                : (details) => onParagraphLongPressMoveUpdate!(
                                    details.globalPosition,
                                  ),
                            onLongPressEnd: onParagraphLongPressEnd == null
                                ? null
                                : (details) =>
                                      onParagraphLongPressEnd!(
                                        details.globalPosition,
                                      ),
                            child: body,
                          ),
                        );
                },
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
