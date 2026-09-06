import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:fqapp/services/episode_source_cache.dart';

void main() {
  test(
    'selection joins a pending prefetch and then reuses its metadata',
    () async {
      final result = Completer<EpisodeSource>();
      var requests = 0;
      final cache = EpisodeSourceCache(
        loader: (_) {
          requests++;
          return result.future;
        },
      );
      addTearDown(cache.dispose);
      final prefetch = cache.prefetch(_chapter('2'), stillWanted: () => true);
      final selected = cache.request(_chapter('2'));
      expect(selected.origin, EpisodeSourceOrigin.prefetchPending);
      expect(requests, 1);
      result.complete(
        const EpisodeSource('https://example.invalid/2.mp4', '1234'),
      );
      await prefetch;
      expect((await selected.future).keyHex, '1234');
      final ready = cache.request(_chapter('2'));
      expect(ready.origin, EpisodeSourceOrigin.prefetchHit);
      expect(identical(await selected.future, await ready.future), true);
      expect(requests, 1);
    },
  );

  test(
    'TTL runs from request start so a slow response does not extend it',
    () async {
      var now = Duration.zero;
      var requests = 0;
      final gate = Completer<EpisodeSource>();
      final cache = EpisodeSourceCache(
        now: () => now,
        loader: (_) {
          requests++;
          return requests == 1 ? gate.future : Future.value(_source('fresh'));
        },
      );
      addTearDown(cache.dispose);
      final first = cache.request(_chapter('1'));
      now = const Duration(seconds: 119);
      gate.complete(_source('old'));
      await first.future;
      expect(cache.request(_chapter('1')).origin, EpisodeSourceOrigin.cacheHit);
      now = const Duration(minutes: 2);
      final expired = cache.request(_chapter('1'));
      expect(expired.origin, EpisodeSourceOrigin.network);
      expect((await expired.future).url, _source('fresh').url);
      expect(requests, 2);
    },
  );

  for (final synchronous in [false, true]) {
    test(
      'failed prefetch is silent and evicted (sync: $synchronous)',
      () async {
        var requests = 0;
        final cache = EpisodeSourceCache(
          loader: (_) {
            if (requests++ == 0) {
              if (synchronous) throw StateError('unavailable');
              return Future.error(StateError('unavailable'));
            }
            return Future.value(_source('ok'));
          },
        );
        addTearDown(cache.dispose);
        await cache.prefetch(_chapter('2'), stillWanted: () => true);
        expect(
          (await cache.request(_chapter('2')).future).url,
          _source('ok').url,
        );
        expect(requests, 2);
      },
    );
  }

  for (final staleFails in [false, true]) {
    test(
      'refresh survives a late obsolete result (error: $staleFails)',
      () async {
        final old = Completer<EpisodeSource>();
        var requests = 0;
        final cache = EpisodeSourceCache(
          loader: (_) {
            return requests++ == 0
                ? old.future
                : Future.value(_source('fresh'));
          },
        );
        addTearDown(cache.dispose);
        final prefetch = cache.prefetch(_chapter('2'), stillWanted: () => true);
        final fresh = cache.request(_chapter('2'), refresh: true);
        expect(fresh.origin, EpisodeSourceOrigin.network);
        expect((await fresh.future).url, _source('fresh').url);
        if (staleFails) {
          old.completeError(StateError('expired request'));
        } else {
          old.complete(_source('old'));
        }
        await prefetch;
        expect(
          (await cache.request(_chapter('2')).future).url,
          _source('fresh').url,
        );
        expect(requests, 2);
      },
    );
  }

  test(
    'refresh bypasses a completed address as well as an in-flight one',
    () async {
      var requests = 0;
      final cache = EpisodeSourceCache(
        loader: (_) async => _source('${++requests}'),
      );
      addTearDown(cache.dispose);
      await cache.prefetch(_chapter('2'), stillWanted: () => true);
      final retry = cache.request(_chapter('2'), refresh: true);
      expect(retry.origin, EpisodeSourceOrigin.network);
      expect((await retry.future).url, _source('2').url);
      expect(requests, 2);
    },
  );

  test(
    'completed metadata is bounded to two entries with recent use retained',
    () async {
      final requests = <String>[];
      final cache = EpisodeSourceCache(
        loader: (chapter) async {
          requests.add(chapter.itemId);
          return _source(chapter.itemId);
        },
      );
      addTearDown(cache.dispose);
      for (final id in ['1', '2', '1', '3', '1', '2']) {
        await cache.request(_chapter(id)).future;
      }
      expect(requests, ['1', '2', '3', '2']);
    },
  );

  test(
    'late responses outside the selected window cannot evict its next episode',
    () async {
      final old = Completer<EpisodeSource>();
      final requests = <String>[];
      final cache = EpisodeSourceCache(
        loader: (chapter) {
          requests.add(chapter.itemId);
          return chapter.itemId == '1'
              ? old.future
              : Future.value(_source(chapter.itemId));
        },
      );
      addTearDown(cache.dispose);
      final first = cache.request(_chapter('1'));
      cache.retainOnly({'3', '4'});
      await cache.request(_chapter('3')).future;
      await cache.prefetch(_chapter('4'), stillWanted: () => true);
      old.complete(_source('1'));
      await first.future;
      expect(
        cache.request(_chapter('4')).origin,
        EpisodeSourceOrigin.prefetchHit,
      );
      expect(cache.request(_chapter('3')).origin, EpisodeSourceOrigin.cacheHit);
      expect(requests, ['1', '3', '4']);
    },
  );

  test(
    'a quick return can join a demand request outside the previous window',
    () async {
      final gate = Completer<EpisodeSource>();
      var requests = 0;
      final cache = EpisodeSourceCache(
        loader: (_) {
          requests++;
          return gate.future;
        },
      );
      addTearDown(cache.dispose);
      cache.retainOnly({'2', '3'});
      final first = cache.request(_chapter('2'));
      cache.retainOnly({'4', '5'});
      cache.retainOnly({'2', '3'});
      final returned = cache.request(_chapter('2'));
      expect(returned.origin, EpisodeSourceOrigin.pending);
      expect(identical(first.future, returned.future), true);
      gate.complete(_source('2'));
      await returned.future;
      expect(requests, 1);
    },
  );

  test('only one prefetch starts and stale queued work is skipped', () async {
    final gate = Completer<EpisodeSource>();
    final requests = <String>[];
    final cache = EpisodeSourceCache(
      loader: (chapter) {
        requests.add(chapter.itemId);
        return chapter.itemId == '2'
            ? gate.future
            : Future.value(_source(chapter.itemId));
      },
    );
    addTearDown(cache.dispose);
    final first = cache.prefetch(_chapter('2'), stillWanted: () => true);
    var wanted = true;
    final stale = cache.prefetch(_chapter('4'), stillWanted: () => wanted);
    final last = cache.prefetch(_chapter('6'), stillWanted: () => true);
    expect(requests, ['2']);
    // Demand must not wait for a speculative request for a different episode.
    await cache.request(_chapter('5')).future;
    expect(requests, ['2', '5']);
    wanted = false;
    gate.complete(_source('2'));
    await Future.wait([first, stale, last]);
    expect(requests, ['2', '5', '6']);
  });

  test(
    'dispose prevents queued or future work even after a late response',
    () async {
      final gate = Completer<EpisodeSource>();
      var requests = 0;
      final cache = EpisodeSourceCache(
        loader: (_) {
          requests++;
          return gate.future;
        },
      );
      final first = cache.prefetch(_chapter('2'), stillWanted: () => true);
      final queued = cache.prefetch(_chapter('4'), stillWanted: () => true);
      cache.dispose();
      gate.complete(_source('late'));
      await Future.wait([first, queued]);
      await cache.prefetch(_chapter('5'), stillWanted: () => true);
      expect(() => cache.request(_chapter('2')), throwsStateError);
      expect(requests, 1);
    },
  );

  test('source parsing preserves encrypted, relative and legacy payloads', () {
    final encrypted = EpisodeSource.fromResponse({
      'data': {
        'video_url': ' https://example.invalid/a.mp4 ',
        'key_hex': ' 1234 ',
      },
    });
    expect(encrypted.url, 'https://example.invalid/a.mp4');
    expect(encrypted.keyHex, '1234');
    final relative = EpisodeSource.fromResponse({'main_url': '/src/a.mp4'});
    expect(relative.url, ApiClient.instance.absoluteUrl('/src/a.mp4'));
    final legacy = EpisodeSource.fromResponse({
      'data': {
        'video_model':
            '{"video_list":[{"main_url":"https://example.invalid/old.mp4"}]}',
      },
    });
    expect(legacy.url, 'https://example.invalid/old.mp4');
    expect(legacy.keyHex, isEmpty);
    expect(() => EpisodeSource.fromResponse({}), throwsA(isA<ApiException>()));
  });
}

Chapter _chapter(String id) => Chapter(itemId: id, title: id, volumeName: '');
EpisodeSource _source(String id) =>
    EpisodeSource('https://example.invalid/$id.mp4');
