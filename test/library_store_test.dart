import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/library_store.dart';

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
}
