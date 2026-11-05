// 书架视图偏好的唯一来源（SharedPreferences）。
//
// Adapted from Wenku8_Flutter (revision ebcd7f1)
// `local_library_preferences.dart` (load/save, author categories, grid
// density, shelf preferences) and `book_collection_mode.dart`.
//
// Mechanical substitutions:
// - upstream stores one JSON record (`localLibraryView.v1`); fqapp keeps one
//   SharedPreferences key per field (`shelfLayout`, `shelfSort`, ...) because
//   the existing app already persisted `bookshelf_layout` there. Per-field
//   keys also make the "load merges user edits field by field" rule simple.
// - `bookshelf_layout` (int 0/1/2/columns) is read once and migrated to the
//   four upstream modes; the legacy key is never written or deleted.
// - `shelf3dEnabled` is a new independent key, with a read-only fallback to
//   the older `performanceShelf3d`.
// - Category selection is per tab: only the shelf tab persists
//   (`shelfCategory`), history/collection remember theirs in memory
//   (decisions #16).
// - `ShelfGroupStore` owns persisted groups; this store only validates the
//   category shape.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/shelf_categories.dart';
import '../models/shelf_view_state.dart';
import '../widgets/wenku/book_collection_layout.dart';
import 'app_log.dart';

/// Device-local view preferences shared by all three shelf tabs.
class ShelfViewStore extends ChangeNotifier {
  ShelfViewStore._();

  static final ShelfViewStore instance = ShelfViewStore._();

  static const String layoutKey = 'shelfLayout';
  static const String legacyLayoutKey = 'bookshelf_layout';
  static const String sortKey = 'shelfSort';
  static const String filterKey = 'shelfFilter';
  static const String sourceKey = 'shelfSourceFilter';
  static const String gridDensityKey = 'shelfGridDensity';
  static const String shelfPreferencesKey = 'shelfPreferences';
  static const String shelfContentKey = 'shelfContent';
  static const String shelf3dKey = 'shelf3dEnabled';
  static const String legacyShelf3dKey = 'performanceShelf3d';
  static const String categoryKey = 'shelfCategory';

  ShelfViewState _state = const ShelfViewState();
  bool _isLoaded = false;
  Future<void>? _loadFuture;
  Future<void> _writes = Future<void>.value();

  /// In-memory category per non-shelf tab; the shelf tab uses
  /// `_state.category`.
  final Map<ShelfTabScope, String> _scopedCategory = {
    ShelfTabScope.history: ShelfCategory.all,
    ShelfTabScope.collection: ShelfCategory.all,
  };

  /// Bumped by every setter. A load only applies the fields whose version did
  /// not change while it was reading, so an edit made during startup is not
  /// overwritten by the snapshot it raced with.
  final Map<String, int> _fieldVersion = {};

  ShelfViewState get state => _state;
  bool get isLoaded => _isLoaded;
  BookCollectionMode get mode => _state.mode;
  BookShelfPreferences get shelfPreferences => _state.shelfPreferences;

  /// Compatibility getter used by page code (design §1.3 #8); same value as
  /// [shelfPreferences].
  BookShelfPreferences get preferences => _state.shelfPreferences;

  /// The persisted category on the shelf tab; history/collection remember
  /// their own in memory and default to 全部.
  String categoryOf(ShelfTabScope scope) => scope == ShelfTabScope.shelf
      ? _state.category
      : _scopedCategory[scope] ?? ShelfCategory.all;

  /// Re-reads every field. Concurrent calls share one read; each field's
  /// in-flight user edit wins over the snapshot being read.
  Future<void> load() {
    final pending = _loadFuture;
    if (pending != null) return pending;
    late final Future<void> future;
    future = _runLoad().whenComplete(() {
      if (identical(_loadFuture, future)) _loadFuture = null;
    });
    _loadFuture = future;
    return future;
  }

  Future<void> _runLoad() async {
    final marks = Map<String, int>.of(_fieldVersion);
    final before = _state;
    final wasLoaded = _isLoaded;
    try {
      final prefs = await SharedPreferences.getInstance();

      BookCollectionMode? mode = BookCollectionMode.tryParse(
        prefs.get(layoutKey),
      );
      var migrateLayout = false;
      if (mode == null) {
        final legacy = prefs.get(legacyLayoutKey);
        if (legacy is int) {
          if (legacy == 0) {
            mode = BookCollectionMode.grid;
            migrateLayout = true;
          } else if (legacy == 1) {
            mode = BookCollectionMode.shelfGrid;
            migrateLayout = true;
          } else if (legacy == 2) {
            mode = BookCollectionMode.list;
            migrateLayout = true;
          } else if (legacy >= 3) {
            mode = BookCollectionMode.grid;
            migrateLayout = true;
          } else {
            // A negative legacy value is out of range: fall back in memory but
            // never overwrite anything.
            mode = BookCollectionMode.grid;
          }
        } else if (legacy == null) {
          mode = BookCollectionMode.shelfList;
        } else {
          // Non-int legacy values (the old `'compact'` string) fall back to
          // the grid without writing a preference.
          mode = BookCollectionMode.grid;
        }
      }

      final sort = ShelfSort.parseOrDefault(prefs.get(sortKey));
      final filter = ShelfReadingFilter.parseOrDefault(prefs.get(filterKey));
      final source = ShelfSourceFilter.parseOrDefault(prefs.get(sourceKey));
      final density = BookGridDensity.parseOrAuto(prefs.get(gridDensityKey));
      final shelfPreferences = BookShelfPreferences.parseOrDefault(
        prefs.get(shelfPreferencesKey),
      );
      // followCollection is fixed true: the featured shelf follows the list
      // below it (decisions #9). The field stays persisted for compatibility.
      final shelfContent = _forceFollow(
        BookShelfContentPreferences.parseOrDefault(prefs.get(shelfContentKey)),
      );
      final shelf3d = _readShelf3d(prefs);
      final storedCategory = prefs.get(categoryKey);
      final category =
          storedCategory is String && isShelfCategoryWellFormed(storedCategory)
          ? storedCategory
          : ShelfCategory.all;

      var next = _state;
      if (_untouched(marks, 'mode')) next = next.copyWith(mode: mode);
      if (_untouched(marks, 'sort')) next = next.copyWith(sort: sort);
      if (_untouched(marks, 'filter')) next = next.copyWith(filter: filter);
      if (_untouched(marks, 'source')) next = next.copyWith(source: source);
      if (_untouched(marks, 'density')) {
        next = next.copyWith(density: density);
      }
      if (_untouched(marks, 'shelfPreferences')) {
        next = next.copyWith(shelfPreferences: shelfPreferences);
      }
      if (_untouched(marks, 'shelfContent')) {
        next = next.copyWith(shelfContent: shelfContent);
      }
      if (_untouched(marks, 'shelf3d')) next = next.copyWith(shelf3d: shelf3d);
      if (_untouched(marks, 'category:shelf')) {
        next = next.copyWith(category: category);
      }

      _state = next;
      _isLoaded = true;
      if (_state != before || !wasLoaded) notifyListeners();

      if (migrateLayout && _untouched(marks, 'mode')) {
        try {
          await _writeString(layoutKey, mode.storageValue);
        } catch (error, stack) {
          // A failed migration keeps the in-memory result and must not take
          // the page down; the next launch retries from the untouched legacy
          // key.
          AppLog.w('shelf_view', '旧书架版式迁移写入失败', error: error, stack: stack);
        }
      }
    } catch (error, stack) {
      // First load: keep defaults but mark loaded so the page can render;
      // later loads keep the current in-memory state (D-M3).
      _isLoaded = true;
      if (!wasLoaded) notifyListeners();
      AppLog.w('shelf_view', '读取书架视图偏好失败，保留当前值', error: error, stack: stack);
    }
  }

  static BookShelfContentPreferences _forceFollow(
    BookShelfContentPreferences value,
  ) => value.followCollection ? value : value.copyWith(followCollection: true);

  static bool _readShelf3d(SharedPreferences prefs) {
    final current = prefs.get(shelf3dKey);
    if (current is bool) return current;
    final legacy = prefs.get(legacyShelf3dKey);
    if (legacy is bool) return legacy;
    return true;
  }

  bool _untouched(Map<String, int> marks, String field) =>
      (_fieldVersion[field] ?? 0) == (marks[field] ?? 0);

  void _touch(String field) {
    _fieldVersion[field] = (_fieldVersion[field] ?? 0) + 1;
  }

  Future<void> setMode(BookCollectionMode value) async {
    _touch('mode');
    if (_state.mode == value) return;
    _state = _state.copyWith(mode: value);
    notifyListeners();
    await _writeString(layoutKey, value.storageValue);
  }

  Future<void> setSort(ShelfSort value) async {
    _touch('sort');
    if (_state.sort == value) return;
    _state = _state.copyWith(sort: value);
    notifyListeners();
    await _writeString(sortKey, value.storageValue);
  }

  Future<void> setFilter(ShelfReadingFilter value) async {
    _touch('filter');
    if (_state.filter == value) return;
    _state = _state.copyWith(filter: value);
    notifyListeners();
    await _writeString(filterKey, value.storageValue);
  }

  Future<void> setSource(ShelfSourceFilter value) async {
    _touch('source');
    if (_state.source == value) return;
    _state = _state.copyWith(source: value);
    notifyListeners();
    await _writeString(sourceKey, value.storageValue);
  }

  Future<void> setGridDensity(BookGridDensity value) async {
    _touch('density');
    if (_state.density == value) return;
    _state = _state.copyWith(density: value);
    notifyListeners();
    await _writeString(gridDensityKey, value.value);
  }

  Future<void> setShelfPreferences(BookShelfPreferences value) async {
    _touch('shelfPreferences');
    if (_state.shelfPreferences == value) return;
    _state = _state.copyWith(shelfPreferences: value);
    notifyListeners();
    await _writeString(shelfPreferencesKey, value.record);
  }

  /// Forces `followCollection = true` both in memory and on disk.
  Future<void> setShelfContent(BookShelfContentPreferences value) async {
    _touch('shelfContent');
    final next = _forceFollow(value);
    if (_state.shelfContent == next) return;
    _state = _state.copyWith(shelfContent: next);
    notifyListeners();
    await _writeString(shelfContentKey, next.record);
  }

  Future<void> setShelf3d(bool value) async {
    _touch('shelf3d');
    if (_state.shelf3d == value) return;
    _state = _state.copyWith(shelf3d: value);
    notifyListeners();
    await _writeBool(shelf3dKey, value);
  }

  /// Persists the shelf tab's category; history/collection keep theirs in
  /// memory only.
  Future<void> setCategoryOf(ShelfTabScope scope, String value) async {
    if (!isShelfCategoryWellFormed(value)) {
      throw const FormatException('分类无效');
    }
    _touch('category:${scope.name}');
    if (scope == ShelfTabScope.shelf) {
      if (_state.category == value) return;
      _state = _state.copyWith(category: value);
      notifyListeners();
      await _writeString(categoryKey, value);
      return;
    }
    if ((_scopedCategory[scope] ?? ShelfCategory.all) == value) return;
    _scopedCategory[scope] = value;
    notifyListeners();
  }

  Future<void> _writeString(String key, String value) => _enqueue(() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = await prefs.setString(key, value);
    if (!saved) throw const FormatException('书架视图偏好保存失败');
  });

  Future<void> _writeBool(String key, bool value) => _enqueue(() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = await prefs.setBool(key, value);
    if (!saved) throw const FormatException('书架视图偏好保存失败');
  });

  /// Serializes writes; a failed write must not poison the queue behind it.
  Future<void> _enqueue(Future<void> Function() action) {
    final work = _writes.catchError((Object _) {}).then((_) => action());
    _writes = work.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return work;
  }

  @visibleForTesting
  void resetForTest() {
    _state = const ShelfViewState();
    _isLoaded = false;
    _loadFuture = null;
    _writes = Future<void>.value();
    _fieldVersion.clear();
    _scopedCategory
      ..clear()
      ..[ShelfTabScope.history] = ShelfCategory.all
      ..[ShelfTabScope.collection] = ShelfCategory.all;
  }

  @visibleForTesting
  Future<void> whenIdle() async {
    final load = _loadFuture;
    if (load != null) {
      try {
        await load;
      } catch (_) {
        // load swallows its own failures; kept defensive for fake stores.
      }
    }
    try {
      await _writes;
    } catch (_) {
      // A failed write is reported to its own caller.
    }
  }
}
