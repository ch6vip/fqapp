import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/reader_full_search.dart';
import 'package:fqapp/services/text_replacement_engine.dart';

final _chapters = [
  for (var i = 0; i < 8; i++)
    Chapter(itemId: '$i', title: 'Chapter $i', volumeName: ''),
];

TextReplacementResult _text() {
  final source = ChapterContent.fromPlainText('old new needle');
  return TextReplacementResult(
    source: source,
    content: source,
    snapshotRevision: 0,
  );
}

void main() {
  test('paces misses serially while cache hits bypass the cooldown', () {
    fakeAsync((time) {
      final cached = {'1', '2', '4', '5', '6', '7'};
      final requests = <int>[];
      final controller = ReaderFullSearchController(
        chapters: _chapters,
        networkElapsed: () => time.elapsed,
        loadChapter: (_) => throw StateError('wrong loader'),
        loadChapterForSearch: (chapter, cancellation) async {
          if (!cached.contains(chapter.itemId)) {
            await cancellation.beforeNetworkFetch();
            requests.add(time.elapsed.inMilliseconds);
            cached.add(chapter.itemId);
          }
          return _text();
        },
      );
      var finished = false;
      unawaited(controller.search('needle').then((_) => finished = true));
      time.elapse(Duration.zero);
      expect(controller.state.scanned, 3);
      expect(requests, [0]);
      time.elapse(const Duration(milliseconds: 299));
      expect(requests, [0]);
      time.elapse(const Duration(milliseconds: 1));
      expect(requests, [0, 300]);
      expect(controller.state.scanned, 8);
      expect(finished, isTrue);
      expect(controller.state.matchCount, 8);

      finished = false;
      unawaited(controller.search('new').then((_) => finished = true));
      time.elapse(Duration.zero);
      expect(finished, isTrue);
      expect(requests, [0, 300]);
      expect(controller.state.matchCount, 8);
      controller.dispose();
      expect(time.pendingTimers, isEmpty);
    });
  });

  test('query change cancels queued wait and retains network cooldown', () {
    fakeAsync((time) {
      final requests = <int>[];
      final controller = ReaderFullSearchController(
        chapters: _chapters.take(2).toList(),
        networkElapsed: () => time.elapsed,
        loadChapter: (_) => throw StateError('wrong loader'),
        loadChapterForSearch: (_, cancellation) async {
          await cancellation.beforeNetworkFetch();
          requests.add(time.elapsed.inMilliseconds);
          return _text();
        },
      );
      var oldFinished = false;
      unawaited(controller.search('old').then((_) => oldFinished = true));
      time.elapse(Duration.zero);
      expect(requests, [0]);
      unawaited(controller.search('new'));
      time.elapse(Duration.zero);
      expect(oldFinished, isTrue);
      expect(controller.state.query, 'new');
      expect(controller.state.scanned, 0);
      time.elapse(const Duration(milliseconds: 299));
      expect(requests, [0]);
      time.elapse(const Duration(milliseconds: 1));
      expect(requests, [0, 300]);
      time.elapse(const Duration(milliseconds: 300));
      expect(requests, [0, 300, 600]);
      expect(controller.state.matchCount, 2);
      expect(controller.state.failedChapters, isEmpty);
      controller.dispose();
    });
  });

  for (final dispose in [false, true]) {
    test('${dispose ? 'dispose' : 'cancel'} wakes a queued network wait', () {
      fakeAsync((time) {
        var requests = 0;
        final controller = ReaderFullSearchController(
          chapters: _chapters,
          networkElapsed: () => time.elapsed,
          loadChapter: (_) => throw StateError('wrong loader'),
          loadChapterForSearch: (_, cancellation) async {
            await cancellation.beforeNetworkFetch();
            ++requests;
            return _text();
          },
        );
        var finished = false;
        unawaited(controller.search('old').then((_) => finished = true));
        time.elapse(Duration.zero);
        expect(requests, 1);
        if (dispose) {
          controller.dispose();
        } else {
          controller.cancel();
        }
        time.flushMicrotasks();
        expect(finished, isTrue);
        expect(requests, 1);
        expect(controller.state.failedChapters, isEmpty);
        time.elapse(const Duration(seconds: 1));
        expect(requests, 1);
        if (!dispose) {
          expect(controller.state.cancelled, isTrue);
          controller.dispose();
        }
        expect(time.pendingTimers, isEmpty);
      });
    });
  }

  test('new query waits for shared in-flight IO without overlapping loads', () {
    fakeAsync((time) {
      final pending = Completer<TextReplacementResult>();
      final starts = <int>[];
      var loads = 0;
      final controller = ReaderFullSearchController(
        chapters: _chapters.take(1).toList(),
        networkElapsed: () => time.elapsed,
        loadChapter: (_) => throw StateError('wrong loader'),
        loadChapterForSearch: (_, cancellation) async {
          await cancellation.beforeNetworkFetch();
          starts.add(time.elapsed.inMilliseconds);
          return ++loads == 1 ? pending.future : _text();
        },
      );
      unawaited(controller.search('old'));
      time.elapse(Duration.zero);
      unawaited(controller.search('new'));
      time.elapse(const Duration(milliseconds: 500));
      expect(loads, 1);
      pending.complete(_text());
      time.elapse(Duration.zero);
      expect(starts, [0, 500]);
      expect(controller.state.query, 'new');
      expect(controller.state.matchCount, 1);
      controller.dispose();
    });
  });
}
