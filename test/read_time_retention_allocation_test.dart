import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/library_store.dart';

void main() {
  late Directory directory;
  final store = LibraryStore.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp(
      'fqapp-retention-allocation-',
    );
    Hive.init(directory.path);
    await store.init();
  });

  tearDown(() async {
    store.maxReadTimeIdentities = 5000;
    store.readTimeRetentionDays = 730;
    await Hive.close();
    await directory.delete(recursive: true);
  });

  Future<void> seedMigratedAudio(DateTime day) async {
    await store.addHistory({'id': 'shared', 'kind': 'audio'});
    await store.accumulateReadTime('shared', 'audio', 30, at: day);
    await store.addHistory({'id': 'shared', 'kind': 'book'});
    expect(store.readTimeSnapshot(), {
      'audio:shared': {'${day.year}-${day.month}-${day.day}': 30.0},
    });
  }

  test(
    'evicting the source cannot charge a later novel against old audio',
    () async {
      final day = DateTime.now().subtract(const Duration(days: 1));
      final key = '${day.year}-${day.month}-${day.day}';
      await seedMigratedAudio(day);
      // The copied source is the oldest physical record. Its removal must not
      // leave an allocation that can subtract seconds from a recreated source.
      store.maxReadTimeIdentities = 2;
      await store.accumulateReadTime(
        'other',
        'book',
        60,
        at: day.add(const Duration(days: 1)),
      );
      expect(Hive.box('read_time').containsKey('shared'), isFalse);
      // Prevent this assertion from depending on which identity the next trim
      // selects. The surviving audio allocation remains part of the snapshot.
      store.maxReadTimeIdentities = 3;
      await store.accumulateReadTime('shared', 'book', 20, at: day);
      expect(store.readTimeSnapshot()['shared'], {key: 20.0});
      expect(store.readTimeSnapshot()['audio:shared'], {key: 30.0});
      await store.init();
      expect(store.readTimeSnapshot()['shared'], {key: 20.0});
    },
  );

  test(
    'evicting allocated audio cannot turn its baseline into novel time',
    () async {
      final day = DateTime.now().subtract(const Duration(days: 1));
      final novelDay = DateTime.now().add(const Duration(days: 1));
      final key = '${novelDay.year}-${novelDay.month}-${novelDay.day}';
      await seedMigratedAudio(day);
      // Touch the novel after preservation, making the allocation the oldest.
      await store.accumulateReadTime('shared', 'book', 20, at: novelDay);
      final times = Hive.box('read_time');
      store.maxReadTimeIdentities = 2;
      await store.accumulateReadTime(
        'other',
        'book',
        60,
        at: novelDay.add(const Duration(days: 1)),
      );
      expect(times.containsKey('audio:shared'), isFalse);
      expect(store.readTimeSnapshot()['shared'], {key: 20.0});
      expect(store.readTimeSnapshot().containsKey('audio:shared'), isFalse);
      await store.init();
      expect(store.readTimeSnapshot()['shared'], {key: 20.0});
    },
  );

  test(
    'an SP backfill after eviction imports only additional old seconds',
    () async {
      final oldDay = DateTime.now().subtract(const Duration(days: 2));
      final newDay = DateTime.now().add(const Duration(days: 1));
      final oldKey = '${oldDay.year}-${oldDay.month}-${oldDay.day}';
      final newKey = '${newDay.year}-${newDay.month}-${newDay.day}';
      await store.addHistory({'id': 'shared', 'kind': 'audio'});
      await store.accumulateReadTime('shared', 'audio', 30, at: oldDay);
      await store.init();
      // The legacy history survives while new novel time is already recorded.
      await store.accumulateReadTime('shared', 'book', 20, at: newDay);
      store.maxReadTimeIdentities = 2;
      await store.accumulateReadTime(
        'other',
        'book',
        60,
        at: newDay.add(const Duration(days: 1)),
      );
      expect(Hive.box('read_time').containsKey('audio:shared'), isFalse);
      store.maxReadTimeIdentities = 3;
      await store.init();
      expect(Hive.box('read_time').containsKey('audio:shared'), isFalse);
      final preferences = await SharedPreferences.getInstance();
      final source = jsonEncode({
        'shared': {oldKey: 40.0},
      });
      for (var attempt = 0; attempt < 3; attempt++) {
        // Retry an import whose final source removal was interrupted as well as
        // the allocation migration itself; neither can resurrect the first 30s.
        await preferences.setString('read_time_map', source);
        await store.init();
        expect(store.readTimeSnapshot()['shared'], {newKey: 20.0});
        expect(store.readTimeSnapshot()['audio:shared'], {oldKey: 10.0});
      }
    },
  );

  test(
    'a persisted eviction interrupted before deletion stays consistent',
    () async {
      final oldDay = DateTime.now().subtract(const Duration(days: 2));
      final newDay = DateTime.now().add(const Duration(days: 1));
      final oldKey = '${oldDay.year}-${oldDay.month}-${oldDay.day}';
      final newKey = '${newDay.year}-${newDay.month}-${newDay.day}';
      await seedMigratedAudio(oldDay);
      await store.accumulateReadTime('shared', 'book', 20, at: newDay);
      final times = Hive.box('read_time');
      // Persist the exact state left by a process interruption after preparing
      // the source ledger, before deleting the allocation target.
      await times.put('shared', {
        ...Map<dynamic, dynamic>.from(times.get('shared') as Map),
        '_allocated_media_time_v1': {oldKey: 30.0},
      });
      await Hive.close();
      await store.init();
      expect(store.readTimeSnapshot()['shared'], {newKey: 20.0});
      expect(store.readTimeSnapshot()['audio:shared'], {oldKey: 30.0});
      // Completing the pending deletion can now only remove audio time.
      await Hive.box('read_time').delete('audio:shared');
      await store.init();
      expect(store.readTimeSnapshot()['shared'], {newKey: 20.0});
      expect(store.readTimeSnapshot().containsKey('audio:shared'), isFalse);
    },
  );

  test(
    'retired baselines obey day retention and clear with reading data',
    () async {
      final start = DateTime.now().subtract(const Duration(days: 5));
      final newDay = DateTime.now().add(const Duration(days: 1));
      final newKey = '${newDay.year}-${newDay.month}-${newDay.day}';
      await store.addHistory({'id': 'shared', 'kind': 'audio'});
      for (var offset = 0; offset < 3; offset++) {
        await store.accumulateReadTime(
          'shared',
          'audio',
          10,
          at: start.add(Duration(days: offset)),
        );
      }
      await store.addHistory({'id': 'shared', 'kind': 'book'});
      await store.accumulateReadTime('shared', 'book', 20, at: newDay);
      store.maxReadTimeIdentities = 2;
      await store.accumulateReadTime(
        'other',
        'book',
        60,
        at: newDay.add(const Duration(days: 1)),
      );
      store.readTimeRetentionDays = 2;
      await store.init();
      final raw = Hive.box('read_time').get('shared') as Map;
      expect(raw['_allocated_media_time_v1'] as Map, hasLength(2));
      expect(store.readTimeSnapshot()['shared'], {newKey: 20.0});
      await store.clearReadingData();
      expect(store.readTimeSnapshot(), isEmpty);
      expect(Hive.box('read_time').length, 0);
    },
  );

  test(
    'a backfill carries retired audio once beside a live manga allocation',
    () async {
      final oldDay = DateTime.now().subtract(const Duration(days: 2));
      final newDay = DateTime.now().add(const Duration(days: 1));
      final oldKey = '${oldDay.year}-${oldDay.month}-${oldDay.day}';
      final newKey = '${newDay.year}-${newDay.month}-${newDay.day}';
      await store.addHistory({'id': 'shared', 'kind': 'audio'});
      await store.accumulateReadTime('shared', 'audio', 30, at: oldDay);
      await store.addHistory({'id': 'shared', 'kind': 'manga'});
      await store.accumulateReadTime('shared', 'manga', 10, at: oldDay);
      await store.accumulateReadTime('shared', 'book', 20, at: newDay);
      // Persist exactly the legitimate eviction boundary for audio, while the
      // separate manga allocation stays live. Force no ordering on same-ms writes.
      final times = Hive.box('read_time');
      await times.put('shared', {
        ...Map<dynamic, dynamic>.from(times.get('shared') as Map),
        '_allocated_media_time_v1': {oldKey: 40.0},
      });
      await times.delete('audio:shared');
      final preferences = await SharedPreferences.getInstance();
      final source = jsonEncode({
        'shared': {oldKey: 50.0},
      });
      for (var attempt = 0; attempt < 2; attempt++) {
        await preferences.setString('read_time_map', source);
        await store.init();
        expect(store.readTimeSnapshot()['shared'], {newKey: 20.0});
        expect(store.readTimeSnapshot()['manga:shared'], {oldKey: 20.0});
        expect(store.readTimeSnapshot().containsKey('audio:shared'), isFalse);
      }
    },
  );

  test(
    'carried retired days stay retired after pruning and another SP retry',
    () async {
      final start = DateTime.now().subtract(const Duration(days: 5));
      final newDay = DateTime.now().add(const Duration(days: 1));
      final newKey = '${newDay.year}-${newDay.month}-${newDay.day}';
      final oldKeys = <String>[];
      await store.addHistory({'id': 'shared', 'kind': 'audio'});
      for (var offset = 0; offset < 3; offset++) {
        final day = start.add(Duration(days: offset));
        oldKeys.add('${day.year}-${day.month}-${day.day}');
        await store.accumulateReadTime('shared', 'audio', 10, at: day);
      }
      await store.init();
      await store.accumulateReadTime('shared', 'book', 20, at: newDay);
      store.maxReadTimeIdentities = 2;
      await store.accumulateReadTime(
        'other',
        'book',
        60,
        at: newDay.add(const Duration(days: 1)),
      );
      expect(Hive.box('read_time').containsKey('audio:shared'), isFalse);
      store.maxReadTimeIdentities = 3;
      final preferences = await SharedPreferences.getInstance();
      final source = jsonEncode({
        'shared': {for (final key in oldKeys) key: 20.0},
      });
      await preferences.setString('read_time_map', source);
      await store.init();
      expect(store.readTimeSnapshot()['audio:shared'], {
        for (final key in oldKeys) key: 10.0,
      });
      store.readTimeRetentionDays = 2;
      for (var attempt = 0; attempt < 2; attempt++) {
        await preferences.setString('read_time_map', source);
        await store.init();
        expect(store.readTimeSnapshot()['shared'], {newKey: 20.0});
        expect(store.readTimeSnapshot()['audio:shared'], {
          for (final key in oldKeys.skip(1)) key: 10.0,
        });
        final raw = Hive.box('read_time').get('audio:shared') as Map;
        final allocation = raw['_legacy_media_time_v1'] as Map;
        expect(allocation['days'] as Map, hasLength(2));
        expect(allocation['discardedDays'] as Map, hasLength(2));
        expect(
          (allocation['discardedDays'] as Map).containsKey(oldKeys.first),
          isFalse,
        );
      }
    },
  );
}
