import 'dart:async';

import 'package:flutter/material.dart';

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

  const ReaderPagedView({
    super.key,
    required this.layout,
    required this.pageIndex,
    required this.hasPreviousChapter,
    required this.hasNextChapter,
    required this.onPageChanged,
    required this.onBoundary,
    required this.onDragStart,
    this.imageProviderFactory,
  });

  @override
  State<ReaderPagedView> createState() => ReaderPagedViewState();
}

class ReaderPagedViewState extends State<ReaderPagedView> {
  late PageController _controller = _newController();
  bool _turning = false;
  bool _boundaryPending = false;
  bool _edgeNotified = false;
  double _overscroll = 0;

  int get _leading => widget.hasPreviousChapter ? 1 : 0;
  int get _itemCount =>
      widget.layout.pages.length + _leading + (widget.hasNextChapter ? 1 : 0);

  PageController _newController() =>
      PageController(initialPage: widget.pageIndex + _leading, keepPage: false);

  @override
  void didUpdateWidget(covariant ReaderPagedView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.layout, widget.layout) ||
        oldWidget.hasPreviousChapter != widget.hasPreviousChapter ||
        oldWidget.hasNextChapter != widget.hasNextChapter) {
      final oldController = _controller;
      _controller = _newController();
      _turning = false;
      _boundaryPending = false;
      oldController.dispose();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

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
      await controller.animateToPage(
        target,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    } finally {
      if (identical(controller, _controller)) _turning = false;
    }
  }

  Future<void> _requestBoundary(int direction) async {
    if (_boundaryPending) return;
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
          if (page < 0) {
            unawaited(_requestBoundary(-1));
          } else if (page >= widget.layout.pages.length) {
            unawaited(_requestBoundary(1));
          } else {
            widget.onPageChanged(page);
          }
        },
        itemBuilder: (context, index) {
          final page = index - _leading;
          if (page < 0 || page >= widget.layout.pages.length) {
            return Center(child: Text(page < 0 ? '上一章' : '下一章'));
          }
          return ReaderPageContent(
            key: ValueKey('reader-text-page-$page'),
            page: widget.layout.pages[page],
            spec: widget.layout.spec,
            imageProviderFactory: widget.imageProviderFactory,
          );
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
