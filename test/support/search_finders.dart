import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/widgets/search/search_discovery.dart';
import 'package:fqapp/widgets/search/search_media_tile.dart';
import 'package:fqapp/widgets/search/search_score_filter.dart';
import 'package:fqapp/widgets/wenku/wenku_ui.dart';

/// Finders for the Wenku8 search page. Tests keep their behavioural
/// assertions; only how a control is located moved with the ported UI.

/// One category or source segment ('综合' … '听书', '书旗').
Finder searchSegment(String label) => find.descendant(
  of: find.byKey(const Key('search-category-tabs')),
  matching: find.text(label),
);

/// The rating filter button on the results heading.
Finder get searchScoreFilter => find.byKey(const Key('search-minimum-score'));

/// Advances the rating filter until it shows [label] ('评分不限', '8 分以上',
/// '9 分以上'). The control steps through its thresholds on each tap.
Future<void> selectSearchScore(WidgetTester tester, String label) async {
  for (var i = 0; i < SearchScoreFilter.thresholds.length; i++) {
    final current = find.descendant(
      of: searchScoreFilter,
      matching: find.text(label),
    );
    if (current.evaluate().isNotEmpty) return;
    await tester.tap(searchScoreFilter);
    await tester.pumpAndSettle();
  }
  throw StateError('Rating filter never showed $label');
}

/// The rating threshold the filter currently shows, as a number.
double searchScoreValue(WidgetTester tester) {
  for (final value in SearchScoreFilter.thresholds) {
    final label = SearchScoreFilter.labelFor(value);
    if (find
        .descendant(of: searchScoreFilter, matching: find.text(label))
        .evaluate()
        .isNotEmpty) {
      return value;
    }
  }
  throw StateError('Rating filter label not found');
}

/// A rendered result, in either list or grid layout.
Finder get searchResultTiles => find.byWidgetPredicate(
  (widget) => widget is SearchNovelRow || widget is SearchBookGridTile,
);

/// Grid tiles only (the cover layout).
Finder get searchGridTiles => find.byType(SearchBookGridTile);

/// Content kinds of the rendered results, top to bottom.
List<String> searchVisibleKinds(WidgetTester tester) => [
  for (final element in searchResultTiles.evaluate())
    switch (element.widget) {
      final SearchNovelRow row => row.item.kind,
      final SearchBookGridTile tile => tile.item.kind,
      _ => throw StateError('unexpected tile'),
    },
];

/// Upstream `FeedFooter` end marker.
const searchEndOfResults = '已经到底了';

/// Upstream `FeedFooter` continuation button label.
const searchLoadMore = '加载更多';

/// Upstream `FeedFooter` retry button for a failed page.
const searchRetry = '重试';

/// Recent-searches heading (shown only when history exists, as upstream).
const searchRecentHeading = '最近搜索';

/// The vertical results list (not the segmented tab row).
Finder get searchResultsScrollable => find
    .descendant(
      of: find.byType(BookCollectionView),
      matching: find.byType(Scrollable),
    )
    .first;

/// The empty-query discovery screen (recent searches and hot list).
Finder get searchDiscoveryScreen => find.byType(SearchDiscoveryView);

/// The first-page skeleton shown while a category loads.
Finder get searchFirstPageSkeleton => find.byType(SearchSkeleton);
