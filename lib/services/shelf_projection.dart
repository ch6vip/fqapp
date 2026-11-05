// 书架投影：排序 + 阅读状态 + 来源 + 分类筛选。
//
// Ported from Wenku8_Flutter (revision ebcd7f1)
// `book_shelf_content_projection.dart` (`shelfContentMatchesReading` /
// `sortShelfContentIds`) and `local_library_preferences.dart`'s `filter` sort
// block.
//
// Mechanical substitutions:
// - upstream sorts integer book ids and looks up keys through `LibraryState`;
//   fqapp rows are [ShelfProjectable] values carrying their own read/added
//   timestamps, so the projection is a pure function over a generic row;
// - category matching is delegated to [ShelfCategoryMatcher] (author
//   categories work even before the group store opens);
// - `original` is intentionally not offered: `ShelfStore.records()` already
//   returns Hive's non-reproducible insertion order.
library;

import 'package:flutter/foundation.dart';

import '../models/shelf_categories.dart';
import '../models/shelf_identity.dart';
import '../models/shelf_view_state.dart';

/// One row the shelf can sort and filter. Implemented by the page's entry
/// model; `contentKey` must be `ShelfIdentity.contentKeyOf(item)`.
abstract interface class ShelfProjectable {
  String get contentKey;
  String get contentId;
  String get kind;
  String get source;
  String get title;
  String get author;
  int? get readTime;
  int get addedAt;
  bool get finished;
}

/// Facts about the offline-cache scan, computed once per shelf rebuild.
@immutable
class ShelfFilterFacts {
  const ShelfFilterFacts({
    this.cachedContentKeys = const <String>{},
    this.cacheScanComplete = false,
  });

  /// Source-qualified keys (`book:123`, never bare `123`). A shuqi book with
  /// the same numeric id therefore cannot match a fanqie cache entry.
  final Set<String> cachedContentKeys;

  /// Until the scan completes, the cached filter matches nothing rather than
  /// claiming books are not cached.
  final bool cacheScanComplete;
}

abstract final class ShelfProjection {
  /// `readTime desc (null/0 last) -> addedAt desc -> contentKey asc` for
  /// [ShelfSort.recentRead]; `recentAdded`/`title` share the same final
  /// tie-break.
  static int compare(ShelfSort sort, ShelfProjectable a, ShelfProjectable b) {
    switch (sort) {
      case ShelfSort.recentRead:
        final readA = _readAt(a);
        final readB = _readAt(b);
        if (readA != readB) return readB.compareTo(readA);
        return _addedThenKey(a, b);
      case ShelfSort.recentAdded:
        return _addedThenKey(a, b);
      case ShelfSort.title:
        final title = a.title.compareTo(b.title);
        return title != 0 ? title : a.contentKey.compareTo(b.contentKey);
    }
  }

  static List<T> apply<T extends ShelfProjectable>(
    Iterable<T> rows, {
    required ShelfSort sort,
    required ShelfReadingFilter reading,
    required ShelfSourceFilter source,
    required String category,
    required ShelfFilterFacts facts,
    required ShelfCategoryMatcher categories,
  }) {
    final result = <T>[];
    for (final row in rows) {
      if (!matchesReading(reading, row)) continue;
      if (!matchesSource(source, row, facts)) continue;
      if (!categories.matchesKey(row.contentKey, row.author, category)) {
        continue;
      }
      result.add(row);
    }
    result.sort((a, b) => compare(sort, a, b));
    return result;
  }

  static bool matchesReading(ShelfReadingFilter filter, ShelfProjectable row) =>
      switch (filter) {
        ShelfReadingFilter.all => true,
        ShelfReadingFilter.unread => row.readTime == null,
        ShelfReadingFilter.reading => row.readTime != null && !row.finished,
        ShelfReadingFilter.finished => row.finished,
      };

  static bool matchesSource(
    ShelfSourceFilter source,
    ShelfProjectable row,
    ShelfFilterFacts facts,
  ) {
    final local = ShelfIdentity.isLocalContentKey(row.contentKey);
    return switch (source) {
      ShelfSourceFilter.all => true,
      ShelfSourceFilter.local => local,
      ShelfSourceFilter.online => !local,
      ShelfSourceFilter.cached =>
        !local &&
            facts.cacheScanComplete &&
            row.kind == 'book' &&
            row.source == ShelfIdentity.fanqie &&
            facts.cachedContentKeys.contains(row.contentKey),
    };
  }

  static int _readAt(ShelfProjectable row) {
    final value = row.readTime;
    return value == null || value <= 0 ? 0 : value;
  }

  static int _addedThenKey(ShelfProjectable a, ShelfProjectable b) {
    final added = b.addedAt.compareTo(a.addedAt);
    return added != 0 ? added : a.contentKey.compareTo(b.contentKey);
  }
}
