import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:fqapp/models/shelf_categories.dart';
import 'package:fqapp/models/shelf_view_state.dart';
import 'package:fqapp/services/shelf_view_store.dart';
import 'package:fqapp/widgets/wenku/book_collection_layout.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final store = ShelfViewStore.instance;

  setUp(() {
    SharedPreferences.resetStatic();
    SharedPreferences.setMockInitialValues({});
    store.resetForTest();
  });

  tearDown(() async {
    await store.whenIdle();
    store.resetForTest();
    SharedPreferences.resetStatic();
  });

  group('load', () {
    test(
      'fresh install defaults to the upstream shelf list and writes nothing',
      () async {
        await store.load();
        expect(store.state, const ShelfViewState());
        expect(store.state.mode, BookCollectionMode.shelfList);
        expect(store.state.sort, ShelfSort.recentRead);
        expect(store.state.filter, ShelfReadingFilter.all);
        expect(store.state.source, ShelfSourceFilter.all);
        expect(store.state.density, const BookGridDensity.auto());
        expect(
          store.state.shelfPreferences,
          const BookShelfPreferences.defaults(),
        );
        expect(store.preferences, store.state.shelfPreferences);
        expect(store.state.shelf3d, isTrue);
        expect(store.isLoaded, isTrue);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getKeys(), isEmpty);
      },
    );

    test(
      'legacy layout ints migrate to the four modes and keep the old key',
      () async {
        const cases = {
          0: BookCollectionMode.grid,
          1: BookCollectionMode.shelfGrid,
          2: BookCollectionMode.list,
          4: BookCollectionMode.grid,
          99: BookCollectionMode.grid,
        };
        for (final entry in cases.entries) {
          SharedPreferences.setMockInitialValues({
            'bookshelf_layout': entry.key,
          });
          store.resetForTest();
          await store.load();
          expect(store.state.mode, entry.value, reason: 'legacy ${entry.key}');
          final prefs = await SharedPreferences.getInstance();
          expect(
            prefs.getString(ShelfViewStore.layoutKey),
            entry.value.storageValue,
          );
          expect(prefs.getInt(ShelfViewStore.legacyLayoutKey), entry.key);
        }
      },
    );

    test(
      'out-of-range legacy values fall back in memory without writing',
      () async {
        for (final value in <Object>[-1, 'compact', true]) {
          SharedPreferences.setMockInitialValues({'bookshelf_layout': value});
          store.resetForTest();
          await store.load();
          expect(store.state.mode, BookCollectionMode.grid, reason: '$value');
          final prefs = await SharedPreferences.getInstance();
          expect(
            prefs.getString(ShelfViewStore.layoutKey),
            isNull,
            reason: 'invalid legacy $value must not write the new key',
          );
          expect(prefs.get(ShelfViewStore.legacyLayoutKey), value);
        }
      },
    );

    test('a valid new key wins over the legacy key', () async {
      SharedPreferences.setMockInitialValues({
        'shelfLayout': 'list',
        'bookshelf_layout': 0,
      });
      await store.load();
      expect(store.state.mode, BookCollectionMode.list);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('shelfLayout'), 'list');
      expect(prefs.getInt('bookshelf_layout'), 0);
    });

    test(
      'an invalid new key without legacy falls back without writing',
      () async {
        SharedPreferences.setMockInitialValues({'shelfLayout': 'bogus'});
        await store.load();
        expect(store.state.mode, BookCollectionMode.shelfList);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('shelfLayout'), 'bogus');
      },
    );

    test('an invalid new key still migrates a valid legacy value', () async {
      SharedPreferences.setMockInitialValues({
        'shelfLayout': 'bogus',
        'bookshelf_layout': 2,
      });
      await store.load();
      expect(store.state.mode, BookCollectionMode.list);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('shelfLayout'), 'list');
    });

    test('every unreadable field falls back independently', () async {
      SharedPreferences.setMockInitialValues({
        'shelfSort': 'bogus',
        'shelfFilter': 'bogus',
        'shelfSourceFilter': 'history',
        'shelfGridDensity': 'bogus',
        'shelfPreferences': 'not json',
        'shelfContent': '{"followCollection":true}',
        'shelf3dEnabled': 'yes',
      });
      await store.load();
      expect(store.state.sort, ShelfSort.recentRead);
      expect(store.state.filter, ShelfReadingFilter.all);
      expect(store.state.source, ShelfSourceFilter.all);
      expect(store.state.density, const BookGridDensity.auto());
      expect(
        store.state.shelfPreferences,
        const BookShelfPreferences.defaults(),
      );
      expect(
        store.state.shelfContent,
        const BookShelfContentPreferences.defaults(),
      );
      expect(store.state.shelf3d, isTrue);
    });

    test('shelf 3d falls back to the legacy performance key', () async {
      SharedPreferences.setMockInitialValues({'performanceShelf3d': false});
      await store.load();
      expect(store.state.shelf3d, isFalse);

      SharedPreferences.resetStatic();
      SharedPreferences.setMockInitialValues({
        'shelf3dEnabled': true,
        'performanceShelf3d': false,
      });
      store.resetForTest();
      await store.load();
      expect(store.state.shelf3d, isTrue);
    });

    test('followCollection is forced true on load', () async {
      SharedPreferences.setMockInitialValues({
        'shelfContent': jsonEncode({
          'followCollection': false,
          'category': ShelfCategory.all,
          'readingFilter': 'all',
          'sort': 'recentRead',
          'source': 'all',
        }),
      });
      await store.load();
      expect(store.state.shelfContent.followCollection, isTrue);
    });

    test(
      'a read failure keeps defaults and still marks the store loaded',
      () async {
        _installPlatform(_ThrowingStore());
        await store.load();
        expect(store.isLoaded, isTrue);
        expect(store.state, const ShelfViewState());
      },
    );

    test('a later read failure keeps the in-memory state', () async {
      SharedPreferences.setMockInitialValues({'shelfSort': 'title'});
      await store.load();
      expect(store.state.sort, ShelfSort.title);

      _installPlatform(_ThrowingStore());
      await store.load();
      expect(store.state.sort, ShelfSort.title);
      expect(store.isLoaded, isTrue);
    });

    test('concurrent load calls share one read', () async {
      final fake = _GatedStore(_prefixed({'shelfLayout': 'grid'}));
      _installPlatform(fake);
      final first = store.load();
      final second = store.load();
      expect(identical(first, second), isTrue);
      fake.gate.complete();
      await Future.wait([first, second]);
      expect(store.state.mode, BookCollectionMode.grid);
    });

    test(
      'a setter during load wins for its field, other fields still load',
      () async {
        final fake = _GatedStore(
          _prefixed({'shelfLayout': 'grid', 'shelfSort': 'title'}),
        );
        _installPlatform(fake);
        final loadFuture = store.load();
        await Future<void>.delayed(Duration.zero);
        final setting = store.setSort(ShelfSort.recentAdded);
        expect(store.state.sort, ShelfSort.recentAdded);
        fake.gate.complete();
        await loadFuture;
        await setting;
        expect(store.state.mode, BookCollectionMode.grid);
        expect(store.state.sort, ShelfSort.recentAdded);
      },
    );
  });

  group('setters', () {
    test('each setter writes its documented key and encoding', () async {
      await store.load();
      await store.setMode(BookCollectionMode.grid);
      await store.setSort(ShelfSort.title);
      await store.setFilter(ShelfReadingFilter.unread);
      await store.setSource(ShelfSourceFilter.cached);
      await store.setGridDensity(const BookGridDensity(3, 4));
      final shelfPreferences = BookShelfPreferences(
        minimumBooks: 2,
        maximumBooks: 5,
        repeatFill: false,
      );
      await store.setShelfPreferences(shelfPreferences);
      await store.setShelfContent(
        const BookShelfContentPreferences(
          followCollection: false,
          category: ShelfCategory.unfiled,
          readingFilter: 'finished',
          sort: ShelfContentSort.title,
          source: 'local',
        ),
      );
      await store.setShelf3d(false);
      await store.setCategoryOf(ShelfTabScope.shelf, ShelfCategory.unfiled);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(ShelfViewStore.layoutKey), 'grid');
      expect(prefs.getString(ShelfViewStore.sortKey), 'title');
      expect(prefs.getString(ShelfViewStore.filterKey), 'unread');
      expect(prefs.getString(ShelfViewStore.sourceKey), 'cached');
      expect(prefs.getString(ShelfViewStore.gridDensityKey), '3x4');
      expect(
        prefs.getString(ShelfViewStore.shelfPreferencesKey),
        shelfPreferences.record,
      );
      expect(prefs.getBool(ShelfViewStore.shelf3dKey), isFalse);
      expect(
        prefs.getString(ShelfViewStore.categoryKey),
        ShelfCategory.unfiled,
      );

      // followCollection is forced true in memory and on disk.
      expect(store.state.shelfContent.followCollection, isTrue);
      final content =
          jsonDecode(prefs.getString(ShelfViewStore.shelfContentKey)!)
              as Map<String, dynamic>;
      expect(content['followCollection'], isTrue);
      expect(content['category'], ShelfCategory.unfiled);
      expect(content['readingFilter'], 'finished');
      expect(content['sort'], 'title');
      expect(content['source'], 'local');
    });

    test('only a changed value notifies', () async {
      await store.load();
      var notifications = 0;
      void listener() => notifications++;
      store.addListener(listener);
      addTearDown(() => store.removeListener(listener));

      await store.setSort(ShelfSort.recentAdded);
      expect(notifications, 1);
      await store.setSort(ShelfSort.recentAdded);
      expect(notifications, 1);
    });

    test(
      'a failed write keeps the chosen value and does not poison the queue',
      () async {
        _installPlatform(_FlakyWriteStore());
        await expectLater(
          store.setMode(BookCollectionMode.list),
          throwsFormatException,
        );
        expect(store.state.mode, BookCollectionMode.list);

        await store.setSort(ShelfSort.title);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString(ShelfViewStore.sortKey), 'title');
      },
    );

    test(
      'category choices are per tab and only the shelf tab persists',
      () async {
        await store.load();
        expect(store.categoryOf(ShelfTabScope.shelf), ShelfCategory.all);
        expect(store.categoryOf(ShelfTabScope.history), ShelfCategory.all);
        expect(store.categoryOf(ShelfTabScope.collection), ShelfCategory.all);

        await store.setCategoryOf(ShelfTabScope.history, ShelfCategory.unfiled);
        expect(store.categoryOf(ShelfTabScope.shelf), ShelfCategory.all);
        expect(store.categoryOf(ShelfTabScope.history), ShelfCategory.unfiled);
        expect(store.categoryOf(ShelfTabScope.collection), ShelfCategory.all);
        expect(
          (await SharedPreferences.getInstance()).getString(
            ShelfViewStore.categoryKey,
          ),
          isNull,
        );

        final author = shelfAuthorCategory('张三');
        await store.setCategoryOf(ShelfTabScope.shelf, author);
        expect(
          (await SharedPreferences.getInstance()).getString(
            ShelfViewStore.categoryKey,
          ),
          author,
        );
        await expectLater(
          store.setCategoryOf(ShelfTabScope.history, 'not a category'),
          throwsFormatException,
        );
      },
    );

    test(
      'resetForTest restores defaults and forgets the loaded flag',
      () async {
        await store.setMode(BookCollectionMode.grid);
        await store.setCategoryOf(ShelfTabScope.history, ShelfCategory.unfiled);
        store.resetForTest();
        expect(store.state, const ShelfViewState());
        expect(store.isLoaded, isFalse);
        expect(store.categoryOf(ShelfTabScope.history), ShelfCategory.all);
      },
    );
  });
}

Map<String, Object> _prefixed(Map<String, Object> values) => {
  for (final entry in values.entries) 'flutter.${entry.key}': entry.value,
};

void _installPlatform(SharedPreferencesStorePlatform platform) {
  SharedPreferences.resetStatic();
  SharedPreferencesStorePlatform.instance = platform;
}

class _ThrowingStore extends InMemorySharedPreferencesStore {
  _ThrowingStore() : super.withData({});

  @override
  Future<Map<String, Object>> getAll() async {
    throw PlatformException(code: 'cannot-read-preferences');
  }
}

class _GatedStore extends InMemorySharedPreferencesStore {
  _GatedStore(super.data) : super.withData();

  final Completer<void> gate = Completer<void>();

  @override
  Future<Map<String, Object>> getAll() async {
    await gate.future;
    return super.getAll();
  }
}

class _FlakyWriteStore extends InMemorySharedPreferencesStore {
  _FlakyWriteStore() : super.withData({});

  bool _failed = false;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (!_failed) {
      _failed = true;
      return false;
    }
    return super.setValue(valueType, key, value);
  }
}
