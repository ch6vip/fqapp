import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/player_history.dart';

import 'support/controlled_player.dart';

void main() {
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
