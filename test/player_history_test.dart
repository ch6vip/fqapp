import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/player_history.dart';

import 'support/controlled_player.dart';

void main() {
  test(
    'manju progress and watched time share the existing video history key',
    () async {
      final store = _KindTrackingStore();
      await PlayerHistory(store).save({
        'id': 'series',
        'kind': 'manju',
        'episodeId': 'episode',
        'position': 37.0,
      }, watchedSeconds: 5);
      expect((await PlayerHistory(store).load('series'))?['kind'], 'manju');
      expect(store.entry?['id'], 'series');
      expect(store.watchedKind, 'manju');
      expect(store.watchedId, 'series');
      expect(store.seconds, 5);
    },
  );

  test(
    'detail resume reads wait for a departing player to save its latest episode',
    () async {
      final gate = Completer<void>();
      final store = ControlledReaderStore(
        entry: {'id': 'book', 'episodeId': '1', 'episode': 0, 'position': 10},
      )..writeGate = gate;
      final save = PlayerHistory(
        store,
      ).save({'id': 'book', 'episodeId': '4', 'episode': 3, 'position': 52});
      var loaded = false;
      final resume = PlayerHistory(store).load('book').then((entry) {
        loaded = true;
        return entry;
      });
      await Future<void>.delayed(Duration.zero);
      expect(loaded, false);
      gate.complete();
      await save;
      final saved = await resume;
      expect(saved?['episodeId'], '4');
      expect(saved?['position'], 52);
    },
  );

  test(
    'statistics failures do not discard resume progress or poison the save queue',
    () async {
      final store = ControlledReaderStore()..failReadTime = true;
      await PlayerHistory(store).save({
        'id': 'book',
        'episodeId': '1',
        'position': 43,
      }, watchedSeconds: 3);
      expect(store.entry?['position'], 43);
      store.failReadTime = false;
      await PlayerHistory(store).save({
        'id': 'book',
        'episodeId': '2',
        'position': 18,
      }, watchedSeconds: 2);
      expect(store.entry?['episodeId'], '2');
      expect(store.entry?['position'], 18);
      expect(store.seconds, 2);
    },
  );
}

class _KindTrackingStore extends ControlledReaderStore {
  String? watchedKind;
  String? watchedId;

  @override
  Future<void> accumulateReadTime(
    String bookId,
    String kind,
    double seconds, {
    DateTime? at,
  }) async {
    watchedId = bookId;
    watchedKind = kind;
    await super.accumulateReadTime(bookId, kind, seconds, at: at);
  }
}
