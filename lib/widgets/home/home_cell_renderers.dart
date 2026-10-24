import 'package:flutter/material.dart';

import '../../models/home_cell.dart';
import '../../models/media_item.dart';
import 'home_cell_blocks.dart';

/// Renders one bookstore block.
typedef HomeCellBuilder =
    Widget Function(
      BuildContext context,
      HomeCell cell, {
      required ValueChanged<MediaItem> onOpen,
    });

/// Registry mapping upstream `show_type` values to block widgets.
///
/// The official client dispatches the same way — `ShowType`, looked up by
/// `showType.ordinal()` in `bookmall/f0.java:159` — but it ships ~300 types
/// because it covers every surface in the app. Here a type is adopted only
/// when the feed actually returns it, and anything unregistered keeps the
/// generic grid, so adding a block can never blank the page.
///
/// Registration happens in [registerDefaultHomeCells]; tests inject their own
/// builders to check dispatch without depending on production widgets.
class HomeCellRenderers {
  HomeCellRenderers._();

  static final Map<int, HomeCellBuilder> _builders = {};

  /// Installs [builder] for [showType]. Re-registering replaces it, which is
  /// what lets a test swap one block without touching the rest.
  static void register(int showType, HomeCellBuilder builder) {
    _builders[showType] = builder;
  }

  /// Removes every registration. Tests use it to start from a known table.
  @visibleForTesting
  static void clear() => _builders.clear();

  /// Whether [showType] has a dedicated widget.
  static bool handles(int showType) => _builders.containsKey(showType);

  /// Number of adopted block types.
  static int get count => _builders.length;

  /// Renders [cell], or null when nothing claims its type.
  ///
  /// Returning null (rather than the fallback) lets the caller decide: the
  /// homepage keeps its existing sliver pipeline untouched while no block type
  /// is adopted.
  static Widget? build(
    BuildContext context,
    HomeCell cell, {
    required ValueChanged<MediaItem> onOpen,
  }) {
    final builder = _builders[cell.showType];
    if (builder == null) return null;
    return builder(context, cell, onOpen: onOpen);
  }
}

/// `RankCellV3` — the rank board preview strip.
const int kHomeCellRank = 511;

/// `MultiTabMixedUnlimitedV2` — a container block that wraps the card stream.
const int kHomeCellMixedFeed = 384;

/// `DoubleRowMixedUnlimitedWithFilter` — the card stream itself, one level
/// inside [kHomeCellMixedFeed].
const int kHomeCellDoubleRowFeed = 385;

/// `MixedDataInUnlimited` — one card inside the stream.
const int kHomeCellMixedItem = 339;

/// Which block owns the visible cards.
///
/// 511 draws its own strip; 384/385 wrap the grid; 339 sits inside a grid and
/// must not draw a section of its own.
const Set<int> kHomeGridBlocks = {kHomeCellMixedFeed, kHomeCellDoubleRowFeed};

/// Whether [cell] renders as a card grid on the homepage.
bool isHomeGridBlock(HomeCell cell) =>
    kHomeGridBlocks.contains(cell.showType) && cell.flatten().isNotEmpty;

/// Adopts the block types this feed actually returns.
///
/// The first tab (`tab_type=2`) ships exactly two blocks — `RankCellV3`(511)
/// 「排行榜」 and `MultiTabMixedUnlimitedV2`(384)「猜你喜欢」 — so those are the
/// ones adopted. Everything else keeps the bare grid in the page pipeline.
///
/// Needs the grid width for the card layout, which the caller knows and this
/// registry does not. Cards inside a grid block are therefore rendered by the
/// homepage itself via [isHomeGridBlock]; only self-contained blocks are
/// registered here.
///
/// Idempotent and cheap enough to call from `build`: the previous entry is
/// replaced in place, and the 「更多」 callback is captured per call so it always
/// points at the current page rather than a disposed one.
///
/// [loadBoard] backs the rank-name strip: picking another board reloads the
/// preview in place (`RankMixContentHolder.K7`) instead of leaving the page.
void registerDefaultHomeCells({
  VoidCallback? onOpenRankBoard,
  HomeRankLoader? loadBoard,
}) {
  HomeCellRenderers.register(
    kHomeCellRank,
    (context, cell, {required onOpen}) => buildRankCell(
      context,
      cell,
      onOpen: onOpen,
      onMore: onOpenRankBoard ?? () {},
      loadBoard: loadBoard,
    ),
  );
}

/// Cards a block should show, using its own cards and then its children's.
///
/// Blocks differ in where they put the payload: `RankCellV3`(511) nests one
/// card per child, `MultiTabMixedUnlimitedV2`(384) wraps a single child holding
/// them all. Both end up here.
List<MediaItem> homeCellCards(HomeCell cell) => cell.flatten();
