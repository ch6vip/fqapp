// 书架视图状态：版式 / 排序 / 筛选 / 分类 / 宫格密度 / 立体书架参数。
//
// Ported from Wenku8_Flutter (revision ebcd7f1):
// - `book_shelf_preferences.dart` -> [BookShelfPreferences]（逐字移植）
// - `book_shelf_content_preferences.dart` -> [BookShelfContentPreferences]
//   （只删掉死值 `history`，其余校验逐字保留）
// - `book_collection_mode.dart` / `book_grid_density.dart` -> fqapp 已有的
//   `lib/widgets/wenku/book_collection_layout.dart` 里的枚举
//
// Mechanical substitutions:
// - 上游 `BookShelfContentSort` 改名 [ShelfContentSort]；
// - 上游按页（书架页 / 本地页）持有偏好实例；这里集中成一个不可变
//   [ShelfViewState]，由 `ShelfViewStore` 持有并持久化；
// - 新增 [ShelfTabScope]，因为 fqapp 的三个 tab 共用一套版式但各自记住
//   自己的分类（只有书架 tab 持久化，见 decisions #16）。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../widgets/wenku/book_collection_layout.dart';
import 'shelf_categories.dart';

/// 三个 tab 共用一套版式偏好，但分类选择按 tab 分别记忆。
enum ShelfTabScope { shelf, history, collection }

/// 排序。默认最近阅读；同值按加入时间、再按内容键稳定排序。
enum ShelfSort {
  recentRead,
  recentAdded,
  title;

  String get storageValue => name;

  static ShelfSort? tryParse(Object? value) => switch (value) {
    'recentRead' => recentRead,
    'recentAdded' => recentAdded,
    'title' => title,
    _ => null,
  };

  static ShelfSort parseOrDefault(Object? value) =>
      tryParse(value) ?? recentRead;
}

/// 阅读状态筛选。`unread` 只看 readTime 是否存在，`finished` 只看完结标记。
enum ShelfReadingFilter {
  all,
  unread,
  reading,
  finished;

  String get storageValue => name;

  static ShelfReadingFilter? tryParse(Object? value) => switch (value) {
    'all' => all,
    'unread' => unread,
    'reading' => reading,
    'finished' => finished,
    _ => null,
  };

  static ShelfReadingFilter parseOrDefault(Object? value) =>
      tryParse(value) ?? all;
}

/// 来源筛选。旧的 `history` 是死值（历史 tab 不筛来源），读取时视为非法。
enum ShelfSourceFilter {
  all,
  local,
  cached,
  online;

  String get storageValue => name;

  static ShelfSourceFilter? tryParse(Object? value) => switch (value) {
    'all' => all,
    'local' => local,
    'cached' => cached,
    'online' => online,
    _ => null,
  };

  static ShelfSourceFilter parseOrDefault(Object? value) =>
      tryParse(value) ?? all;
}

/// 立体书架独立投影的排序（上游预留，UI 不暴露；followCollection 恒 true）。
enum ShelfContentSort { original, recentRead, recentAdded, title }

/// 立体书架的显示本数。数量不限制收藏本身，只决定书架区展示多少本。
@immutable
class BookShelfPreferences {
  const BookShelfPreferences.defaults()
    : minimumBooks = 1,
      maximumBooks = 10,
      repeatFill = true;

  factory BookShelfPreferences({
    int minimumBooks = 1,
    int maximumBooks = 10,
    bool repeatFill = true,
  }) {
    if (!_validCount(minimumBooks) || !_validCount(maximumBooks)) {
      throw const FormatException('立体书架数量须为 1–100 本');
    }
    return BookShelfPreferences._(minimumBooks, maximumBooks, repeatFill);
  }

  const BookShelfPreferences._(
    this.minimumBooks,
    this.maximumBooks,
    this.repeatFill,
  );

  static const int maximum = 100;
  final int minimumBooks;
  final int maximumBooks;
  final bool repeatFill;

  int featuredCount(int available) =>
      available < minimumBooks ? 0 : available.clamp(0, maximumBooks);

  BookShelfPreferences copyWith({
    int? minimumBooks,
    int? maximumBooks,
    bool? repeatFill,
  }) => BookShelfPreferences(
    minimumBooks: minimumBooks ?? this.minimumBooks,
    maximumBooks: maximumBooks ?? this.maximumBooks,
    repeatFill: repeatFill ?? this.repeatFill,
  );

  Map<String, Object> toJson() => {
    'minimumBooks': minimumBooks,
    'maximumBooks': maximumBooks,
    'repeatFill': repeatFill,
  };

  String get record => _encodeRecord(toJson());

  static bool _validCount(Object? value) =>
      value is int && value >= 1 && value <= maximum;

  static BookShelfPreferences? tryParse(Object? value) {
    value = _decodeRecord(value);
    if (value is! Map ||
        !_validCount(value['minimumBooks']) ||
        !_validCount(value['maximumBooks']) ||
        value.containsKey('repeatFill') && value['repeatFill'] is! bool) {
      return null;
    }
    return BookShelfPreferences._(
      value['minimumBooks'] as int,
      value['maximumBooks'] as int,
      value['repeatFill'] as bool? ?? true,
    );
  }

  static BookShelfPreferences parseOrDefault(Object? value) =>
      tryParse(value) ?? const BookShelfPreferences.defaults();

  @override
  bool operator ==(Object other) =>
      other is BookShelfPreferences &&
      minimumBooks == other.minimumBooks &&
      maximumBooks == other.maximumBooks &&
      repeatFill == other.repeatFill;

  @override
  int get hashCode => Object.hash(minimumBooks, maximumBooks, repeatFill);
}

/// 立体书架独立投影偏好。`followCollection` 在持久化层被强制为 true
/// （decisions #9：立体书架跟随下方列表），字段只为上游兼容保留。
@immutable
class BookShelfContentPreferences {
  const BookShelfContentPreferences.defaults()
    : followCollection = true,
      category = ShelfCategory.all,
      readingFilter = 'all',
      sort = ShelfContentSort.recentRead,
      source = 'all';

  const BookShelfContentPreferences({
    this.followCollection = true,
    this.category = ShelfCategory.all,
    this.readingFilter = 'all',
    this.sort = ShelfContentSort.recentRead,
    this.source = 'all',
  });

  static const Set<String> readingFilters = {
    'all',
    'recent',
    'unread',
    'reading',
    'finished',
  };
  static const Set<String> sources = {'all', 'local', 'cached', 'online'};

  final bool followCollection;
  final String category;
  final String readingFilter;
  final ShelfContentSort sort;
  final String source;

  BookShelfContentPreferences copyWith({
    bool? followCollection,
    String? category,
    String? readingFilter,
    ShelfContentSort? sort,
    String? source,
  }) => BookShelfContentPreferences(
    followCollection: followCollection ?? this.followCollection,
    category: category ?? this.category,
    readingFilter: readingFilter ?? this.readingFilter,
    sort: sort ?? this.sort,
    source: source ?? this.source,
  );

  Map<String, Object> toJson() => {
    'followCollection': followCollection,
    'category': category,
    'readingFilter': readingFilter,
    'sort': sort.name,
    'source': source,
  };

  String get record => _encodeRecord(toJson());

  static BookShelfContentPreferences? tryParse(Object? value) {
    value = _decodeRecord(value);
    if (value is! Map ||
        value['followCollection'] is! bool ||
        value['category'] is! String ||
        (value['category'] as String).isEmpty ||
        (value['category'] as String).length > 512 ||
        !readingFilters.contains(value['readingFilter']) ||
        !sources.contains(value['source'])) {
      return null;
    }
    final sortName = value['sort'];
    ShelfContentSort? sort;
    for (final candidate in ShelfContentSort.values) {
      if (candidate.name == sortName) {
        sort = candidate;
        break;
      }
    }
    if (sort == null) return null;
    return BookShelfContentPreferences(
      followCollection: value['followCollection'] as bool,
      category: value['category'] as String,
      readingFilter: value['readingFilter'] as String,
      sort: sort,
      source: value['source'] as String,
    );
  }

  static BookShelfContentPreferences parseOrDefault(Object? value) =>
      tryParse(value) ?? const BookShelfContentPreferences.defaults();

  @override
  bool operator ==(Object other) =>
      other is BookShelfContentPreferences &&
      followCollection == other.followCollection &&
      category == other.category &&
      readingFilter == other.readingFilter &&
      sort == other.sort &&
      source == other.source;

  @override
  int get hashCode =>
      Object.hash(followCollection, category, readingFilter, sort, source);
}

String _encodeRecord(Map<String, Object> value) => jsonEncode(value);

Object? _decodeRecord(Object? value) {
  if (value is! String) return value;
  try {
    return jsonDecode(value);
  } on FormatException {
    return null;
  }
}

/// 一次书架渲染所需的全部视图偏好。
@immutable
class ShelfViewState {
  const ShelfViewState({
    this.mode = BookCollectionMode.shelfList,
    this.sort = ShelfSort.recentRead,
    this.filter = ShelfReadingFilter.all,
    this.source = ShelfSourceFilter.all,
    this.category = ShelfCategory.all,
    this.density = const BookGridDensity.auto(),
    this.shelfPreferences = const BookShelfPreferences.defaults(),
    this.shelfContent = const BookShelfContentPreferences.defaults(),
    this.shelf3d = true,
  });

  final BookCollectionMode mode;
  final ShelfSort sort;
  final ShelfReadingFilter filter;
  final ShelfSourceFilter source;

  /// 仅书架 tab 持久化；历史/收藏 tab 由 `ShelfViewStore` 在内存里各自记忆。
  final String category;
  final BookGridDensity density;
  final BookShelfPreferences shelfPreferences;

  /// followCollection 恒为 true；数据模型按上游预留独立筛选字段。
  final BookShelfContentPreferences shelfContent;
  final bool shelf3d;

  ShelfViewState copyWith({
    BookCollectionMode? mode,
    ShelfSort? sort,
    ShelfReadingFilter? filter,
    ShelfSourceFilter? source,
    String? category,
    BookGridDensity? density,
    BookShelfPreferences? shelfPreferences,
    BookShelfContentPreferences? shelfContent,
    bool? shelf3d,
  }) => ShelfViewState(
    mode: mode ?? this.mode,
    sort: sort ?? this.sort,
    filter: filter ?? this.filter,
    source: source ?? this.source,
    category: category ?? this.category,
    density: density ?? this.density,
    shelfPreferences: shelfPreferences ?? this.shelfPreferences,
    shelfContent: shelfContent ?? this.shelfContent,
    shelf3d: shelf3d ?? this.shelf3d,
  );

  @override
  bool operator ==(Object other) =>
      other is ShelfViewState &&
      mode == other.mode &&
      sort == other.sort &&
      filter == other.filter &&
      source == other.source &&
      category == other.category &&
      density == other.density &&
      shelfPreferences == other.shelfPreferences &&
      shelfContent == other.shelfContent &&
      shelf3d == other.shelf3d;

  @override
  int get hashCode => Object.hash(
    mode,
    sort,
    filter,
    source,
    category,
    density,
    shelfPreferences,
    shelfContent,
    shelf3d,
  );
}
