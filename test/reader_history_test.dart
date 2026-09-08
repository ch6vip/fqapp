import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/reader_history.dart';

import 'support/controlled_player.dart';

void main() {
  test(
    'saving after a failed first insert retries the full novel record',
    () async {
      final store = ControlledReaderStore(
        entry: {
          'id': 'shared',
          'kind': 'audio',
          'chapterId': 'audio-chapter',
          'position': 45.0,
        },
      )..failNextWrite = true;
      final history = ReaderHistory(store);
      await history.save({
        'id': 'shared',
        'kind': 'book',
        'title': '小说',
        'chapterId': 'book-chapter',
        'episode': 0,
        'position': 0.0,
        'maxScroll': 1000.0,
        'progress': 0.0,
      }, createHistory: true);
      expect(store.entry?['kind'], 'audio');
      expect(store.entry?['position'], 45.0);
      await ReaderHistory(store).save({
        'id': 'shared',
        'kind': 'book',
        'title': '小说',
        'chapterId': 'book-chapter',
        'episode': 0,
        'position': 300.0,
        'maxScroll': 1000.0,
        'progress': 0.3,
      });
      final saved = await history.load('shared');
      expect(saved?['kind'], 'book');
      expect(saved?['title'], '小说');
      expect(saved?['chapterId'], 'book-chapter');
      expect(saved?['position'], 300.0);
    },
  );
}
