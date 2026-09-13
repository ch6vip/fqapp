import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/library_store.dart';

void main() {
  late Directory directory;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp(
      'fqapp-read-time-review-',
    );
    Hive.init(directory.path);
    await LibraryStore.instance.init();
  });

  tearDown(() async {
    LibraryStore.instance.readTimeRetentionDays = 730;
    LibraryStore.instance.maxReadTimeIdentities = 5000;
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test('day buckets beyond the retention window are dropped', () async {
    final store = LibraryStore.instance;
    store.readTimeRetentionDays = 30;
    for (var i = 0; i < 40; i++) {
      await store.accumulateReadTime(
        'book-a',
        'book',
        1,
        at: DateTime(2026, 1, 1).add(Duration(days: i)),
      );
    }

    final days = store.readTimeSnapshot()['book-a']!;
    expect(days, hasLength(30));
    expect(days.containsKey('2026-1-1'), isFalse);
    expect(days.containsKey('2026-1-11'), isTrue);
    expect(days.containsKey('2026-2-9'), isTrue);
    expect(days.values.fold<double>(0, (a, b) => a + b), 30.0);
  });

  test('recent day buckets are untouched by retention', () async {
    final store = LibraryStore.instance;
    store.readTimeRetentionDays = 30;
    await store.accumulateReadTime(
      'book-a',
      'book',
      30,
      at: DateTime(2026, 9, 1),
    );
    await store.accumulateReadTime(
      'book-a',
      'book',
      90,
      at: DateTime(2026, 9, 2),
    );

    expect(store.readTimeSnapshot()['book-a'], {
      '2026-9-1': 30.0,
      '2026-9-2': 90.0,
    });
  });

  test('the identity cap evicts the least recently touched record', () async {
    final store = LibraryStore.instance;
    store.maxReadTimeIdentities = 3;
    for (final id in ['a', 'b', 'c', 'd', 'e']) {
      await store.accumulateReadTime(
        'book-$id',
        'book',
        60,
        at: DateTime(2026, 9, 1 + 'abcde'.indexOf(id)),
      );
    }

    expect(store.readTimeSnapshot().keys.toSet(), {
      'book-c',
      'book-d',
      'book-e',
    });
    expect(store.readTimeKindSnapshot().keys.toSet(), {
      'book-c',
      'book-d',
      'book-e',
    });
  });

  test(
    'a migrated identity keeps at most the retention window of days',
    () async {
      final store = LibraryStore.instance;
      store.readTimeRetentionDays = 3;
      await store.addHistory({'id': 'shared', 'kind': 'audio', 'position': 1});
      for (var i = 0; i < 3; i++) {
        await store.accumulateReadTime(
          'shared',
          'audio',
          10,
          at: DateTime(2026, 1, 1).add(Duration(days: i)),
        );
      }
      // Reusing the raw id for a novel allocates the old audio days to the
      // scoped key; fresh scoped days must not push the merged window past 3.
      await store.addHistory({'id': 'shared', 'kind': 'book', 'position': 2});
      for (var i = 0; i < 5; i++) {
        await store.accumulateReadTime(
          'audio:shared',
          'audio',
          10,
          at: DateTime(2026, 9, 1).add(Duration(days: i)),
        );
      }

      final days = store.readTimeSnapshot()['audio:shared'];
      expect(days, isNotNull);
      expect(days!.length, lessThanOrEqualTo(3));
    },
  );

  test('overlapping allocation days keep their seconds', () async {
    final store = LibraryStore.instance;
    store.readTimeRetentionDays = 30;
    await store.addHistory({'id': 'shared', 'kind': 'audio', 'position': 1});
    await store.accumulateReadTime(
      'shared',
      'audio',
      5,
      at: DateTime(2026, 1, 2),
    );
    await store.init();
    await store.accumulateReadTime(
      'audio:shared',
      'audio',
      10,
      at: DateTime(2026, 1, 2),
    );
    await store.accumulateReadTime(
      'audio:shared',
      'audio',
      10,
      at: DateTime(2026, 1, 3),
    );

    final days = store.readTimeSnapshot()['audio:shared'];
    expect(days, isNotNull);
    // The allocation's 5s on the same day must merge with the 10s, not vanish.
    expect(days!['2026-1-2'], 15.0);
    expect(days['2026-1-3'], 10.0);
  });

  test('the snapshot window is capped for a migrated identity', () async {
    final store = LibraryStore.instance;
    store.readTimeRetentionDays = 3;
    await store.addHistory({'id': 'shared', 'kind': 'audio', 'position': 1});
    for (var i = 0; i < 3; i++) {
      await store.accumulateReadTime(
        'shared',
        'audio',
        10,
        at: DateTime(2026, 1, 1).add(Duration(days: i)),
      );
    }
    await store.init();
    for (var i = 0; i < 3; i++) {
      await store.accumulateReadTime(
        'audio:shared',
        'audio',
        10,
        at: DateTime(2026, 9, 1).add(Duration(days: i)),
      );
    }

    final days = store.readTimeSnapshot()['audio:shared'];
    expect(days, isNotNull);
    expect(days!.length, lessThanOrEqualTo(3));
  });

  test('a history entry without read time creates no empty record', () async {
    final store = LibraryStore.instance;
    await store.addHistory({'id': 'lonely', 'kind': 'audio', 'position': 1});
    await store.addHistory({'id': 'lonely', 'kind': 'book', 'position': 2});
    expect(Hive.box('read_time').length, 0);
  });

  test(
    'empty legacy histories cannot evict real records under the cap',
    () async {
      final store = LibraryStore.instance;
      store.maxReadTimeIdentities = 3;
      for (var i = 0; i < 3; i++) {
        await store.accumulateReadTime(
          'real-$i',
          'book',
          60,
          at: DateTime(2026, 9, 1),
        );
      }
      for (var i = 0; i < 10; i++) {
        await store.addHistory({
          'id': 'legacy-$i',
          'kind': 'audio',
          'position': 1,
        });
        await store.addHistory({
          'id': 'legacy-$i',
          'kind': 'book',
          'position': 2,
        });
      }

      expect(
        store.readTimeKindSnapshot().keys,
        containsAll(['real-0', 'real-1', 'real-2']),
      );
    },
  );

  test('init prunes records written before retention existed', () async {
    final store = LibraryStore.instance;
    store.readTimeRetentionDays = 730;
    for (var i = 0; i < 40; i++) {
      await store.accumulateReadTime(
        'book-a',
        'book',
        1,
        at: DateTime(2026, 1, 1).add(Duration(days: i)),
      );
    }
    expect(store.readTimeSnapshot()['book-a'], hasLength(40));

    store.readTimeRetentionDays = 30;
    await store.init();
    expect(store.readTimeSnapshot()['book-a'], hasLength(30));
  });

  test('init enforces the identity cap on an oversized box', () async {
    final store = LibraryStore.instance;
    for (final id in ['a', 'b', 'c', 'd', 'e']) {
      await store.accumulateReadTime(
        'book-$id',
        'book',
        60,
        at: DateTime(2026, 9, 1 + 'abcde'.indexOf(id)),
      );
    }
    expect(store.readTimeSnapshot(), hasLength(5));

    store.maxReadTimeIdentities = 3;
    await store.init();
    expect(store.readTimeSnapshot(), hasLength(3));
  });

  test(
    'the identity cap also applies to the legacy preservation path',
    () async {
      final store = LibraryStore.instance;
      store.maxReadTimeIdentities = 1;
      await store.addHistory({'id': 'shared', 'kind': 'audio', 'position': 1});
      await store.accumulateReadTime(
        'shared',
        'audio',
        30,
        at: DateTime(2026, 9, 1),
      );
      // Saving a novel under the same id preserves the old audio seconds under
      // the scoped key, which writes a second read-time record.
      await store.addHistory({'id': 'shared', 'kind': 'book', 'position': 2});

      expect(Hive.box('read_time').length, lessThanOrEqualTo(1));
    },
  );
}
