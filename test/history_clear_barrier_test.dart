import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/audio_history.dart';
import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/services/media_history_store.dart';
import 'package:fqapp/services/player_history.dart';
import 'package:fqapp/services/reader_history.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final store = LibraryStore.instance;
  late Directory directory;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('fqapp-history-clear-');
    Hive.init(directory.path);
    await store.init();
  });

  tearDown(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  for (final kind in ['book', 'manga', 'audio', 'video', 'manju']) {
    test('$kind save initiated before clear cannot restore history', () async {
      final saved = _save(store, kind, 'old');
      final cleared = store.clearHistory();
      await Future.wait([saved, cleared]);

      expect(store.historySnapshot(), isEmpty);
    });

    test('$kind queued saves stay cleared and a newer save survives', () async {
      final first = _save(store, kind, 'old-a');
      final second = _save(store, kind, 'old-b');
      final cleared = store.clearHistory();
      final newest = _save(store, kind, 'new');
      await Future.wait([first, second, cleared, newest]);

      final history = store.historySnapshot();
      expect(history, hasLength(1));
      expect(historyContentId(history.single), 'new');
      expect(history.single['kind'], kind);

      // Clearing history intentionally keeps the reading-time statistics.
      if (_hasPlaybackTime(kind)) {
        expect(_totalSeconds(store), 6);
      }
    });
  }

  for (final kind in ['audio', 'video', 'manju']) {
    for (final clearAll in [false, true]) {
      test('$kind clear during statistics write (all: $clearAll)', () async {
        final readingTime = Hive.box('read_time');
        final oldKey = _hasAudioScope(kind) ? 'audio:old' : 'old';
        final written = readingTime.watch(key: oldKey).first;
        final saved = _save(store, kind, 'old');
        // Observe a real Hive time write while the wrapper is still awaiting
        // accumulateReadTime; it has not submitted its history snapshot yet.
        await written;
        expect(store.historySnapshot(), isEmpty);
        final cleared = clearAll
            ? store.clearReadingData()
            : store.clearHistory();
        final newest = _save(store, kind, 'new', seconds: 7);
        await Future.wait([saved, cleared, newest]);

        expect(store.historySnapshot(), hasLength(1));
        expect(historyContentId(store.historySnapshot().single), 'new');
        expect(_totalSeconds(store), clearAll ? 7 : 9);
      });
    }

    test('$kind queued time cannot reappear after clearing all data', () async {
      await store.accumulateReadTime('previous', 'book', 11);
      final first = _save(store, kind, 'old-a');
      final second = _save(store, kind, 'old-b');
      final cleared = store.clearReadingData();
      await Future.wait([first, second, cleared]);

      expect(store.historySnapshot(), isEmpty);
      expect(store.readTimeSnapshot(), isEmpty);
    });

    test('$kind save after clearing keeps its own new reading time', () async {
      final first = _save(store, kind, 'old-a');
      final second = _save(store, kind, 'old-b');
      final cleared = store.clearReadingData();
      final newest = _save(store, kind, 'new', seconds: 7);
      await Future.wait([first, second, cleared, newest]);

      final history = store.historySnapshot();
      expect(history, hasLength(1));
      expect(historyContentId(history.single), 'new');
      final time = store.readTimeSnapshot();
      expect(time.keys, [_hasAudioScope(kind) ? 'audio:new' : 'new']);
      expect(_totalSeconds(store), 7);
    });
  }

  for (final kind in ['audio', 'manga']) {
    test(
      '$kind legacy progress copy cannot cross the clear boundary',
      () async {
        await Hive.box(
          'history',
        ).put('old', {'id': 'old', 'kind': kind, 'position': 12, 'time': 1});
        final pending = scopedHistoryStore(
          store,
          kind,
        ).updateProgress('old', 1, 0.5, position: 24);
        final cleared = store.clearHistory();
        await Future.wait([pending, cleared]);
        expect(store.historySnapshot(), isEmpty);
      },
    );
  }

  test('direct reading time started after clearing remains recorded', () async {
    await store.accumulateReadTime('old', 'book', 10);
    final cleared = store.clearReadingData();
    final newer = store.accumulateReadTime('new', 'book', 7);
    await Future.wait([cleared, newer]);

    expect(store.readTimeSnapshot().keys, ['new']);
    expect(_totalSeconds(store), 7);
  });

  test(
    'legacy preservation cannot revive an identity across a clear',
    () async {
      await Hive.box('history').put('shared', {
        'id': 'shared',
        'kind': 'audio',
        'position': 45,
        'time': 1,
      });
      await Hive.box('read_time').put('shared', {'2026-9-16': 23.0});

      final replacing = store.addHistory({
        'id': 'shared',
        'kind': 'book',
        'position': 200,
        'time': 2,
      });
      final cleared = store.clearReadingData();
      final newest = _save(store, 'audio', 'shared', seconds: 7);
      await Future.wait([replacing, cleared, newest]);

      final history = store.historySnapshot();
      expect(history, hasLength(1));
      expect(history.single['id'], 'audio:shared');
      expect(history.single['position'], 12);
      expect(store.readTimeSnapshot().keys, ['audio:shared']);
      expect(_totalSeconds(store), 7);
    },
  );

  test(
    'history clearing does not interrupt legacy time preservation',
    () async {
      await Hive.box(
        'history',
      ).put('shared', {'id': 'shared', 'kind': 'audio', 'time': 1});
      await Hive.box('read_time').put('shared', {'2026-9-16': 23.0});

      final accumulating = store.accumulateReadTime('shared', 'book', 7);
      final cleared = store.clearHistory();
      await Future.wait([accumulating, cleared]);

      expect(store.historySnapshot(), isEmpty);
      expect(_totalSeconds(store), 30);
    },
  );

  test(
    'a failed history write does not poison clearing or later saves',
    () async {
      await Hive.box('history').close();
      await _save(store, 'audio', 'failed');
      await store.init();
      final cleared = store.clearReadingData();
      final saved = _save(store, 'audio', 'new', seconds: 7);
      await Future.wait([cleared, saved]);

      expect(store.historySnapshot(), hasLength(1));
      expect(historyContentId(store.historySnapshot().single), 'new');
      expect(_totalSeconds(store), 7);
    },
  );
}

bool _hasAudioScope(String kind) => kind == 'audio';

bool _hasPlaybackTime(String kind) =>
    kind == 'audio' || kind == 'video' || kind == 'manju';

Future<void> _save(
  LibraryStore store,
  String kind,
  String id, {
  double seconds = 2,
}) {
  final entry = <String, dynamic>{
    'id': id,
    'kind': kind,
    'chapterId': 'chapter',
    'episode': 0,
    'position': 12.0,
    'time': 3,
  };
  return switch (kind) {
    'audio' => AudioHistory(store).save(entry, listenedSeconds: seconds),
    'video' ||
    'manju' => PlayerHistory(store).save(entry, watchedSeconds: seconds),
    _ => ReaderHistory(
      kind == 'manga' ? scopedHistoryStore(store, kind) : store,
    ).save(entry),
  };
}

double _totalSeconds(LibraryStore store) =>
    store.readTimeSnapshot().values.fold(
      0.0,
      (total, days) =>
          total + days.values.fold(0.0, (sum, seconds) => sum + seconds),
    );
