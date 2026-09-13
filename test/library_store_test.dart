import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/services/media_history_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final store = LibraryStore.instance;
  late Directory directory;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('fqapp-library-test-');
    Hive.init(directory.path);
  });

  tearDown(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test(
    'migration skips damaged entries and retains all valid history',
    () async {
      SharedPreferences.setMockInitialValues({
        'hist': jsonEncode([
          {'id': 'new', 'title': 'New book', 'time': 200},
          'damaged entry',
          {'id': 'old', 'title': 'Old book', 'time': 100},
        ]),
        'read_time_map': jsonEncode({
          'new': {'2026-9-8': 60, 'damaged': 'not a number'},
          'damaged': 42,
        }),
      });
      await store.init();
      expect(store.historySnapshot().map((entry) => entry['id']), [
        'new',
        'old',
      ]);
      expect(store.readTimeSnapshot(), {
        'new': {'2026-9-8': 60.0},
      });
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.containsKey('hist'), isFalse);
      expect(preferences.containsKey('read_time_map'), isFalse);
    },
  );

  test(
    'partial migrations resume without replacing newer saved data',
    () async {
      final history = await Hive.openBox('history');
      await history.put('existing', {
        'id': 'existing',
        'title': 'Current title',
        'episode': 5,
      });
      final readTime = await Hive.openBox('read_time');
      await readTime.put('existing', {'2026-9-8': 90.0});
      SharedPreferences.setMockInitialValues({
        'hist': jsonEncode([
          {'id': 'existing', 'title': 'Legacy title', 'episode': 1},
          {'id': 'missing', 'title': 'Still to migrate'},
        ]),
        'read_time_map': jsonEncode({
          'existing': {'2026-9-8': 30, '2026-9-7': 40},
          'missing': {'2026-9-8': 20},
        }),
      });
      await store.init();
      expect((await store.historyEntry('existing'))?['title'], 'Current title');
      expect(
        (await store.historyEntry('missing'))?['title'],
        'Still to migrate',
      );
      expect(store.readTimeSnapshot(), {
        'existing': {'2026-9-8': 90.0, '2026-9-7': 40.0},
        'missing': {'2026-9-8': 20.0},
      });
    },
  );

  test(
    'a failed migration write leaves the original history recoverable',
    () async {
      final source = jsonEncode([
        {'id': 'remaining', 'title': 'Remaining book'},
        {'id': 'x' * 256, 'title': 'Hive rejects an oversized key'},
        {'id': 'written', 'title': 'Already written'},
      ]);
      SharedPreferences.setMockInitialValues({'hist': source});
      await store.init();
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getString('hist'), source);
      expect(await store.historyEntry('written'), isNotNull);
      expect(await store.historyEntry('remaining'), isNull);

      await preferences.setString(
        'hist',
        jsonEncode([
          {'id': 'remaining', 'title': 'Remaining book'},
          {'id': 'written', 'title': 'Already written'},
        ]),
      );
      await store.init();
      expect(await store.historyEntry('remaining'), isNotNull);
      expect(preferences.containsKey('hist'), isFalse);
    },
  );

  test('truncated migration sources are not deleted', () async {
    SharedPreferences.setMockInitialValues({
      'hist': '[{"id":"unfinished"',
      'read_time_map': '{"unfinished":',
    });
    await store.init();
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.containsKey('hist'), isTrue);
    expect(preferences.containsKey('read_time_map'), isTrue);
    expect(store.historySnapshot(), isEmpty);
    expect(store.readTimeSnapshot(), isEmpty);
  });

  test(
    'damaged Hive records cannot break history or reading statistics',
    () async {
      await store.init();
      final history = Hive.box('history');
      await history.putAll({
        'valid': {'id': 'valid', 'time': 20, 'episode': '2', 'progress': '0.5'},
        'damaged': 'not a history record',
        'bad-fields': {
          'id': 'bad-fields',
          'time': 'invalid',
          'episode': double.nan,
          'progress': double.infinity,
          'position': -1,
        },
        'bad-time': {'id': 'bad-time', 'time': 1e100},
      });
      final entries = store.historySnapshot();
      expect(entries, hasLength(3));
      expect(entries.first['id'], 'valid');
      expect(entries.first['episode'], 2);
      expect(entries.first['progress'], .5);
      expect(await store.historyEntry('damaged'), isNull);
      expect((await store.historyEntry('bad-time'))?['time'], 0);
      expect((await store.historyEntry('bad-fields'))?['episode'], isNull);
      await store.updateProgress('damaged', 1, .5);

      final readTime = Hive.box('read_time');
      await readTime.putAll({
        'valid': {'2026-9-8': 60, 'bad': 'invalid', 'negative': -5},
        'damaged': 'invalid',
        'non-finite': {'2026-9-8': double.nan},
      });
      expect(store.readTimeSnapshot(), {
        'valid': {'2026-9-8': 60.0},
      });
      final today = DateTime(2026, 9, 8);
      await Future.wait([
        store.accumulateReadTime('damaged', 'book', 10, at: today),
        store.accumulateReadTime('damaged', 'book', 20, at: today),
        store.accumulateReadTime('ignored', 'book', double.infinity, at: today),
      ]);
      expect(store.readTimeSnapshot()['damaged'], {'2026-9-8': 30.0});
      expect(store.readTimeSnapshot().containsKey('ignored'), isFalse);
      // A numeric media kind is metadata, not a reading day.
      await store.accumulateReadTime('numeric-kind', '123', 60, at: today);
      expect(store.readTimeSnapshot()['numeric-kind'], {'2026-9-8': 60.0});
      expect(store.readTimeKindSnapshot()['numeric-kind'], '123');
    },
  );

  test(
    'history trimming removes actual keys despite damaged record IDs',
    () async {
      await store.init();
      final history = Hive.box('history');
      await history.putAll({
        for (var index = 0; index < 100; index++)
          'key-$index': index == 0
              ? 'damaged'
              : {'id': 'wrong-id', 'time': index},
      });
      await store.addHistory({'id': 'new', 'title': 'Newest', 'time': 1000});
      expect(history.length, 50);
      expect(store.historySnapshot(), hasLength(50));
      expect(store.historySnapshot().first['id'], 'new');
    },
  );

  test(
    'audio and manga progress remain separate from a novel with the same ID',
    () async {
      await store.init();
      final audio = scopedHistoryStore(store, 'audio');
      final manga = scopedHistoryStore(store, 'manga');
      await store.addHistory({
        'id': 'shared',
        'kind': 'book',
        'position': 450.0,
        'time': 1,
      });
      await audio.addHistory({
        'id': 'shared',
        'kind': 'audio',
        'bookId': 'shared',
        'position': 12.5,
        'time': 2,
      });
      await manga.addHistory({
        'id': 'shared',
        'kind': 'manga',
        'position': 3.25,
        'positionUnit': 'comic-page',
        'time': 3,
      });
      await manga.updateProgress(
        'shared',
        2,
        .5,
        chapterId: 'c3',
        position: 4.5,
        maxScroll: 9,
      );
      expect((await store.historyEntry('shared'))?['position'], 450.0);
      expect((await audio.historyEntry('shared'))?['position'], 12.5);
      expect((await manga.historyEntry('shared'))?['position'], 4.5);
      expect(
        (await manga.historyEntry('shared'))?['positionUnit'],
        'comic-page',
      );
      expect((await audio.historyEntry('shared'))?['id'], 'shared');
      expect(store.historySnapshot(), hasLength(3));
      for (final entry in store.historySnapshot()) {
        expect(historyContentId(entry), 'shared');
      }
      final audioEntry = store.historySnapshot().firstWhere(
        (entry) => entry['kind'] == 'audio',
      );
      expect(historyStatisticsId(audioEntry), 'audio:shared');

      final today = DateTime(2026, 9, 8);
      await store.accumulateReadTime('shared', 'book', 20, at: today);
      await audio.accumulateReadTime('shared', 'audio', 30, at: today);
      await manga.accumulateReadTime('shared', 'manga', 40, at: today);
      expect(store.readTimeSnapshot(), {
        'shared': {'2026-9-8': 20.0},
        'audio:shared': {'2026-9-8': 30.0},
        'manga:shared': {'2026-9-8': 40.0},
      });
    },
  );

  test(
    'scoped history accepts matching legacy records and rejects other units',
    () async {
      await store.init();
      final audio = scopedHistoryStore(store, 'audio');
      final manga = scopedHistoryStore(store, 'manga');
      await store.addHistory({
        'id': 'legacy',
        'kind': 'audio',
        'position': 45.0,
      });
      expect((await audio.historyEntry('legacy'))?['position'], 45.0);
      expect(await manga.historyEntry('legacy'), isNull);
      await store.addHistory({'id': 'untyped', 'position': 4000.0});
      expect(await audio.historyEntry('untyped'), isNull);
      expect(await manga.historyEntry('untyped'), isNull);
      expect(identical(audio, scopedHistoryStore(store, 'audio')), isTrue);
      expect(identical(audio, scopedHistoryStore(audio, 'audio')), isTrue);
      expect(identical(manga, scopedHistoryStore(audio, 'manga')), isTrue);
    },
  );

  test(
    'saving legacy audio shows one shelf item and counts old seconds once',
    () async {
      await store.init();
      final today = DateTime(2026, 9, 8);
      await store.addHistory({
        'id': 'shared',
        'kind': 'audio',
        'position': 45,
        'time': 100,
      });
      await store.accumulateReadTime('shared', 'audio', 60, at: today);
      final audio = scopedHistoryStore(store, 'audio');
      await audio.addHistory({
        'id': 'shared',
        'kind': 'audio',
        'position': 70,
        // The scoped record wins even if an older device's clock was ahead.
        'time': 50,
      });
      await audio.accumulateReadTime('shared', 'audio', 30, at: today);
      final shelf = store.historySnapshot();
      expect(shelf, hasLength(1));
      expect(shelf.single['position'], 70.0);
      expect(historyContentId(shelf.single), 'shared');
      expect(historyStatisticsId(shelf.single), 'audio:shared');
      expect(store.readTimeSnapshot(), {
        'audio:shared': {'2026-9-8': 90.0},
      });
      expect((await store.historyEntry('shared'))?['position'], 45.0);

      await store.init();
      await audio.addHistory({'id': 'shared', 'kind': 'audio', 'position': 71});
      expect(store.historySnapshot(), hasLength(1));
      expect(store.readTimeSnapshot(), {
        'audio:shared': {'2026-9-8': 90.0},
      });
      // Preservation keeps the original counters; it does not destructively
      // rewrite them or rely on deleting a source after copying its seconds.
      expect(Hive.box('read_time').get('shared'), {
        '2026-9-8': 60.0,
        '_media_kind_v1': 'audio',
        '_last_touched_v1': today.millisecondsSinceEpoch,
      });
    },
  );

  test(
    'opening a novel first preserves legacy listening progress and time',
    () async {
      await store.init();
      final today = DateTime(2026, 9, 8);
      await store.addHistory({
        'id': 'shared',
        'kind': 'audio',
        'chapterId': 'audio-chapter',
        'position': 45,
      });
      await store.accumulateReadTime('shared', 'audio', 60, at: today);
      await store.addHistory({
        'id': 'shared',
        'kind': 'book',
        'chapterId': 'book-chapter',
        'position': 800,
      });
      await store.accumulateReadTime('shared', 'book', 20, at: today);
      final audio = scopedHistoryStore(store, 'audio');
      expect((await audio.historyEntry('shared'))?['position'], 45.0);
      expect(
        (await audio.historyEntry('shared'))?['chapterId'],
        'audio-chapter',
      );
      expect((await store.historyEntry('shared'))?['position'], 800.0);
      await audio.accumulateReadTime('shared', 'audio', 10, at: today);
      expect(store.historySnapshot(), hasLength(2));
      expect(store.historySnapshot().map((entry) => entry['kind']).toSet(), {
        'book',
        'audio',
      });
      expect(store.readTimeSnapshot(), {
        'shared': {'2026-9-8': 20.0},
        'audio:shared': {'2026-9-8': 70.0},
      });
      await store.init();
      expect(store.readTimeSnapshot(), {
        'shared': {'2026-9-8': 20.0},
        'audio:shared': {'2026-9-8': 70.0},
      });
    },
  );

  test(
    'startup finishes a copied legacy record without replacing newer progress',
    () async {
      final history = await Hive.openBox('history');
      final times = await Hive.openBox('read_time');
      await history.putAll({
        'legacy': {'kind': 'audio', 'position': 10, 'time': 10},
        'audio:legacy': {
          'kind': 'audio',
          'contentId': 'legacy',
          'position': 33,
          'time': 20,
        },
      });
      await times.putAll({
        'legacy': {'2026-9-7': 90.0},
        'audio:legacy': {'2026-9-7': 10.0},
      });
      for (var attempt = 0; attempt < 2; attempt++) {
        await store.init();
        expect(store.historySnapshot(), hasLength(1));
        expect(store.historySnapshot().single['position'], 33.0);
        expect(store.readTimeSnapshot(), {
          'audio:legacy': {'2026-9-7': 100.0},
        });
      }
      await scopedHistoryStore(
        store,
        'audio',
      ).accumulateReadTime('legacy', 'audio', 5, at: DateTime(2026, 9, 7));
      await store.init();
      expect(store.readTimeSnapshot(), {
        'audio:legacy': {'2026-9-7': 105.0},
      });
    },
  );

  test(
    'a failed preservation leaves legacy data intact and can be retried',
    () async {
      await store.init();
      await store.addHistory({'id': 'legacy', 'kind': 'audio', 'position': 45});
      await store.accumulateReadTime(
        'legacy',
        'audio',
        60,
        at: DateTime(2026, 9, 8),
      );
      await Hive.box('read_time').close();
      await expectLater(
        store.addHistory({'id': 'legacy', 'kind': 'book', 'position': 900}),
        throwsA(isA<HiveError>()),
      );
      expect((await store.historyEntry('legacy'))?['kind'], 'audio');
      await store.init();
      await store.addHistory({'id': 'legacy', 'kind': 'book', 'position': 900});
      expect((await store.historyEntry('legacy'))?['kind'], 'book');
      expect(
        (await scopedHistoryStore(
          store,
          'audio',
        ).historyEntry('legacy'))?['position'],
        45.0,
      );
      expect(store.readTimeSnapshot(), {
        'audio:legacy': {'2026-9-8': 60.0},
      });
    },
  );

  test('partial progress updates cannot overwrite unscoped media', () async {
    await store.init();
    for (final kind in ['audio', 'manga']) {
      final legacy = {
        'id': kind,
        'kind': kind,
        'chapterId': '$kind-chapter',
        'episode': 2,
        'position': 45.0,
        'progress': 0.25,
      };
      await store.addHistory(legacy);
      await store.updateProgress(
        kind,
        9,
        0.8,
        chapterId: 'novel-chapter',
        position: 800,
        maxScroll: 1000,
      );
      expect(await store.historyEntry(kind), legacy);
    }
  });

  test(
    'novel time is isolated while its first full history save still needs retry',
    () async {
      await store.init();
      // A failed startup preservation leaves the original record and counters
      // present, but no allocation yet. Reading time can arrive before the
      // next complete novel history snapshot is saved successfully.
      await Hive.box('history').put('shared', {
        'id': 'shared',
        'kind': 'audio',
        'chapterId': 'audio-chapter',
        'position': 45.0,
      });
      await Hive.box('read_time').put('shared', {'2026-9-8': 60.0});
      final today = DateTime(2026, 9, 8);
      await store
          .accumulateReadTime('shared', 'book', 10, at: today)
          .timeout(const Duration(seconds: 3));
      expect((await store.historyEntry('shared'))?['kind'], 'audio');
      expect((await store.historyEntry('shared'))?['position'], 45.0);
      expect(store.readTimeSnapshot(), {
        'shared': {'2026-9-8': 10.0},
        'audio:shared': {'2026-9-8': 60.0},
      });
      await store.init();
      expect(store.readTimeSnapshot(), {
        'shared': {'2026-9-8': 10.0},
        'audio:shared': {'2026-9-8': 60.0},
      });
      await store.addHistory({
        'id': 'shared',
        'kind': 'book',
        'chapterId': 'book-chapter',
        'position': 300.0,
      });
      await store.accumulateReadTime('shared', 'book', 20, at: today);
      await store.init();
      expect((await store.historyEntry('shared'))?['kind'], 'book');
      expect((await store.historyEntry('audio:shared'))?['position'], 45.0);
      expect(store.readTimeSnapshot(), {
        'shared': {'2026-9-8': 30.0},
        'audio:shared': {'2026-9-8': 60.0},
      });
    },
  );

  test(
    'existing legacy allocation includes dates backfilled by SP retry',
    () async {
      final history = await Hive.openBox('history');
      final times = await Hive.openBox('read_time');
      await history.put('shared', {'kind': 'audio', 'position': 45});
      await times.putAll({
        'shared': {'2026-9-8': 60.0},
        'audio:shared': {
          '_legacy_media_time_v1': {
            'sourceId': 'shared',
            'days': {'2026-9-8': 60.0},
          },
        },
      });
      SharedPreferences.setMockInitialValues({
        'read_time_map': jsonEncode({
          'shared': {'2026-9-7': 30, '2026-9-8': 60},
        }),
      });
      await store.init();
      await store.addHistory({'id': 'shared', 'kind': 'book', 'position': 300});
      await store.accumulateReadTime(
        'shared',
        'book',
        20,
        at: DateTime(2026, 9, 8),
      );
      for (var attempt = 0; attempt < 2; attempt++) {
        await store.init();
        expect(store.readTimeSnapshot(), {
          'shared': {'2026-9-8': 20.0},
          'audio:shared': {'2026-9-7': 30.0, '2026-9-8': 60.0},
        });
      }
    },
  );

  test(
    'SP retry keeps old and new seconds recorded on the same date',
    () async {
      await store.init();
      await Hive.box(
        'history',
      ).put('shared', {'kind': 'audio', 'position': 45});
      await Hive.box('read_time').put('shared', {'2026-9-8': 60.0});
      final day = DateTime(2026, 9, 7);
      await store.accumulateReadTime('shared', 'book', 20, at: day);
      final source = jsonEncode({
        'shared': {'2026-9-7': 30, '2026-9-8': 60},
      });
      // Simulate retrying both the import and its final source-removal step.
      for (var attempt = 0; attempt < 2; attempt++) {
        final preferences = await SharedPreferences.getInstance();
        await preferences.setString('read_time_map', source);
        await store.init();
        expect(store.readTimeSnapshot(), {
          'shared': {'2026-9-7': 20.0},
          'audio:shared': {'2026-9-7': 30.0, '2026-9-8': 60.0},
        });
      }
      await store.addHistory({'id': 'shared', 'kind': 'book', 'position': 300});
      await store.accumulateReadTime('shared', 'book', 10, at: day);
      await store.init();
      expect(store.readTimeSnapshot(), {
        'shared': {'2026-9-7': 30.0},
        'audio:shared': {'2026-9-7': 30.0, '2026-9-8': 60.0},
      });
    },
  );

  test(
    'statistics normalize typed legacy media before a scoped save',
    () async {
      await store.init();
      await store.addHistory({'id': 'legacy', 'kind': 'manga', 'position': 3});
      await store.accumulateReadTime(
        'legacy',
        'manga',
        90,
        at: DateTime(2026, 9, 8),
      );
      expect(
        historyStatisticsId(store.historySnapshot().single),
        'manga:legacy',
      );
      expect(store.readTimeSnapshot(), {
        'manga:legacy': {'2026-9-8': 90.0},
      });
    },
  );

  test(
    'history trimming retains fifty distinct items despite legacy backups',
    () async {
      await store.init();
      final history = Hive.box('history');
      await history.putAll({
        for (var index = 0; index < 60; index++) ...{
          '$index': {'kind': 'audio', 'time': index},
          'audio:$index': {
            'kind': 'audio',
            'contentId': '$index',
            'time': index + 60,
          },
        },
      });
      await store.addHistory({'id': 'new', 'kind': 'book', 'time': 1000});
      final visible = store.historySnapshot();
      expect(visible, hasLength(50));
      expect(visible.first['id'], 'new');
      expect(
        visible
            .map((entry) => (entry['kind'], historyContentId(entry)))
            .toSet(),
        hasLength(50),
      );
      expect(history.length, 99);
    },
  );
}
