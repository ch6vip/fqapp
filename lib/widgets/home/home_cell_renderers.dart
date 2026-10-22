import 'package:flutter/material.dart';

import '../../models/home_cell.dart';
import '../../models/media_item.dart';

/// Renders one bookstore block.
///
/// [fallback] draws the same block with the generic card grid, so a block type
/// that has no dedicated widget yet still shows its books instead of a gap.
typedef HomeCellBuilder =
    Widget Function(
      BuildContext context,
      HomeCell cell, {
      required Widget fallback,
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
    required Widget Function() fallback,
  }) {
    final builder = _builders[cell.showType];
    if (builder == null) return null;
    return builder(context, cell, fallback: fallback());
  }
}

/// Adopts the block types this build knows how to draw.
///
/// Intentionally empty for now. The feed's first tab returns two block types —
/// `RankCellV3`(511)「排行榜」 and `MultiTabMixedUnlimitedV2`(384)「猜你喜欢」 —
/// and neither has a widget yet, so every block keeps the generic grid and the
/// homepage looks exactly as before. The framework lands first so that adopting
/// a type is a one-line change here plus its widget, not another data-layer
/// migration.
///
/// Idempotent: calling it twice replaces nothing that was not already set.
void registerDefaultHomeCells() {
  // Populated as block types are adopted; see home_cell_renderers notes.
}

/// Cards a block should show, using its own cards and then its children's.
///
/// Blocks differ in where they put the payload: `RankCellV3`(511) nests one
/// card per child, `MultiTabMixedUnlimitedV2`(384) wraps a single child holding
/// them all. Both end up here.
List<MediaItem> homeCellCards(HomeCell cell) => cell.flatten();
