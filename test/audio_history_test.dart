import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/audio_history.dart';

import 'support/controlled_player.dart';

void main() {
  final chapters = [
    Chapter(itemId: 'first', title: '第一章', volumeName: ''),
    Chapter(itemId: 'second', title: '第二章', volumeName: ''),
  ];

  test('only typed audio history can supply a listening position', () async {
    for (final kind in [null, 'book', 'video', 'manga']) {
      final store = ControlledReaderStore(
        entry: {'id': 'book', 'kind': kind, 'episode': 0, 'position': 800},
      );
      expect(await AudioHistory(store).load('book'), isNull);
      expect(resumeAudioChapterIndex(store.entry, chapters), isNull);
    }
  });

  test(
    'chapter identity survives directory reorder and rejects missing IDs',
    () {
      expect(
        resumeAudioChapterIndex({
          'kind': 'audio',
          'chapterId': 'second',
          'episode': 0,
        }, chapters),
        1,
      );
      expect(
        resumeAudioChapterIndex({
          'kind': 'audio',
          'chapterId': 'removed',
          'episode': 0,
        }, chapters),
        isNull,
      );
      expect(
        resumeAudioChapterIndex({'kind': 'audio', 'episode': 1}, chapters),
        1,
      );
      for (final index in [-1, 0.5, 2, double.nan, double.infinity, '1']) {
        expect(
          resumeAudioChapterIndex({
            'kind': 'audio',
            'episode': index,
          }, chapters),
          isNull,
        );
      }
    },
  );

  test(
    'a new page waits for the departing page to save its latest position',
    () async {
      final gate = Completer<void>();
      final store = ControlledReaderStore(
        entry: {
          'id': 'book',
          'kind': 'audio',
          'chapterId': 'first',
          'position': 3,
        },
      )..writeGate = gate;
      final write = AudioHistory(
        store,
      ).save({'id': 'book', 'chapterId': 'second', 'position': 73.5});
      var loaded = false;
      final read = AudioHistory(store).load('book').then((saved) {
        loaded = true;
        return saved;
      });
      await Future<void>.delayed(Duration.zero);
      expect(loaded, false);
      gate.complete();
      await write;
      final saved = await read;
      expect(saved?['id'], 'book');
      expect(saved?['chapterId'], 'second');
      expect(saved?['position'], 73.5);
      expect(store.entry?['id'], 'audio:book');
      expect(store.entry?['kind'], 'audio');
    },
  );

  test(
    'statistics and storage failures do not discard subsequent progress',
    () async {
      final store = _AudioStatisticsStore()..failReadTime = true;
      await AudioHistory(
        store,
      ).save({'id': 'book', 'position': 40}, listenedSeconds: 3);
      expect(store.entry?['position'], 40);
      store.failReadTime = false;
      store.failNextWrite = true;
      await AudioHistory(store).save({'id': 'book', 'position': 41});
      await AudioHistory(
        store,
      ).save({'id': 'book', 'position': 42}, listenedSeconds: 2);
      expect(store.entry?['position'], 42);
      expect(store.seconds, 2);
      expect(store.statisticsId, 'audio:book');
      expect(store.statisticsKind, 'audio');
    },
  );

  test('saving captures values before waiting for an earlier write', () async {
    final gate = Completer<void>();
    final store = ControlledReaderStore()..writeGate = gate;
    final snapshot = <String, dynamic>{'id': 'book', 'position': 37};
    final write = AudioHistory(store).save(snapshot);
    snapshot['position'] = 99;
    gate.complete();
    await write;
    expect(store.entry?['position'], 37);
  });
}

class _AudioStatisticsStore extends ControlledReaderStore {
  String? statisticsId;
  String? statisticsKind;

  @override
  Future<void> accumulateReadTime(
    String bookId,
    String kind,
    double seconds, {
    DateTime? at,
  }) async {
    statisticsId = bookId;
    statisticsKind = kind;
    await super.accumulateReadTime(bookId, kind, seconds, at: at);
  }
}
