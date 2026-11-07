// Ported from Wenku8_Flutter (revision ebcd7f1):
//   lib/book_collection_layout.dart `BookCollectionView.builder` composition
//   (the collection sliver itself is already ported in
//   `lib/widgets/wenku/book_collection_layout.dart`).
//
// fqapp additions:
// - `regionToolbar` and the optional `carousel` are leading slivers; the item
//   builder receives the *item* index (leading slots are subtracted).
// - `maxContentWidth` centers the content on wide panes without narrowing the
//   scrollable itself.
// - An empty collection renders a plain CustomScrollView (toolbar + empty
//   state) instead of `BookCollectionView.builder`, whose
//   `itemCount >= leadingCount + trailingCount` assert cannot hold at zero
//   items (design §1.3 item 9).
// - `storageKey` is a PageStorageKey on the outer widget; PageStorage walks up
//   from the scrollable and finds it, so the scroll offset survives tab
//   switches without changing the shared collection API.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../wenku/book_collection_layout.dart';

/// The four-mode collection container: region toolbar, optional 3D carousel,
/// then the lazy list/grid rows.
class ShelfCollectionView extends StatelessWidget {
  const ShelfCollectionView({
    super.key,
    required this.mode,
    required this.density,
    required this.itemCount,
    required this.regionToolbar,
    this.carousel,
    required this.itemBuilder,
    required this.emptyBuilder,
    required this.padding,
    this.storageKey,
    this.physics = const AlwaysScrollableScrollPhysics(),
    this.controller,
    this.onGridViewport,
    this.maxContentWidth,
  });
  final BookCollectionMode mode;
  final BookGridDensity density;
  final int itemCount;
  final Widget regionToolbar;
  final Widget? carousel;

  /// Builds one row; `index` is the item index (0-based, leading slots
  /// already removed).
  final Widget Function(BuildContext context, int index) itemBuilder;
  final WidgetBuilder emptyBuilder;
  final EdgeInsets padding;
  final PageStorageKey<String>? storageKey;
  final ScrollPhysics? physics;
  final ScrollController? controller;
  final ValueChanged<BookGridViewport>? onGridViewport;
  final double? maxContentWidth;

  @override
  Widget build(BuildContext context) {
    final showCarousel = mode.hasShelf && carousel != null;
    final leading = 1 + (showCarousel ? 1 : 0);
    return LayoutBuilder(
      builder: (context, constraints) {
        final inset = maxContentWidth == null
            ? 0.0
            : math.max(0.0, (constraints.maxWidth - maxContentWidth!) / 2);
        final effectivePadding = EdgeInsets.fromLTRB(
          padding.left + inset,
          padding.top,
          padding.right + inset,
          padding.bottom,
        );
        if (itemCount == 0) {
          return CustomScrollView(
            key: storageKey,
            physics: physics,
            controller: controller,
            slivers: [
              SliverPadding(
                padding: effectivePadding,
                sliver: SliverMainAxisGroup(
                  slivers: [
                    SliverToBoxAdapter(child: regionToolbar),
                    if (showCarousel) SliverToBoxAdapter(child: carousel!),
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: emptyBuilder(context),
                    ),
                  ],
                ),
              ),
            ],
          );
        }
        return BookCollectionView.builder(
          key: storageKey,
          controller: controller,
          physics: physics,
          padding: effectivePadding,
          grid: mode.isGrid,
          gridDensity: density,
          onGridViewport: onGridViewport,
          itemCount: itemCount + leading,
          leadingCount: leading,
          itemBuilder: (context, index) {
            if (index == 0) return regionToolbar;
            if (showCarousel && index == 1) return carousel!;
            return itemBuilder(context, index - leading);
          },
        );
      },
    );
  }
}
