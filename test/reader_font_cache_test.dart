import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/reader_device.dart';

void main() {
  setUp(ReaderFonts.debugReset);
  tearDown(ReaderFonts.debugReset);

  test('bounds the path cache while reusing loaded families', () async {
    ReaderFonts.debugLoader = (_) async {};
    final families = <String?>[];
    for (var i = 0; i < ReaderFonts.maxFamilies; i++) {
      families.add(await ReaderFonts.load('/font-$i.ttf'));
    }
    expect(ReaderFonts.debugLoadedFamilies, ReaderFonts.maxFamilies);
    expect(ReaderFonts.debugCachedPaths, ReaderFonts.maxCachedPaths);

    // The most recent path is still cached and must not import a new family.
    final reused = await ReaderFonts.load('/font-15.ttf');
    expect(reused, families.last);
    expect(ReaderFonts.debugLoadedFamilies, ReaderFonts.maxFamilies);
  });

  test('refuses to import beyond the family cap', () async {
    ReaderFonts.debugLoader = (_) async {};
    for (var i = 0; i < ReaderFonts.maxFamilies; i++) {
      await ReaderFonts.load('/font-$i.ttf');
    }
    await expectLater(
      ReaderFonts.load('/font-overflow.ttf'),
      throwsA(isA<ReaderFontLimitException>()),
    );
    expect(ReaderFonts.debugLoadedFamilies, ReaderFonts.maxFamilies);
  });

  test('a failed import is not cached and does not consume the cap', () async {
    var calls = 0;
    ReaderFonts.debugLoader = (path) async {
      calls++;
      if (path == '/bad.ttf') throw const FormatException('bad');
    };
    await expectLater(
      ReaderFonts.load('/bad.ttf'),
      throwsA(isA<FormatException>()),
    );
    expect(ReaderFonts.debugCachedPaths, 0);
    expect(ReaderFonts.debugLoadedFamilies, 0);

    expect(await ReaderFonts.load('/good.ttf'), isNotNull);
    expect(calls, 2);
    expect(ReaderFonts.debugLoadedFamilies, 1);
  });

  test('concurrent imports cannot exceed the family cap', () async {
    final gate = Completer<void>();
    ReaderFonts.debugLoader = (_) => gate.future;
    final futures = <Future<Object?>>[
      for (var i = 0; i < ReaderFonts.maxFamilies + 5; i++)
        ReaderFonts.load(
          '/font-$i.ttf',
        ).then<Object?>((family) => family).catchError((Object error) => error),
    ];
    gate.complete();
    final results = await Future.wait(futures);
    expect(results.whereType<String>().length, ReaderFonts.maxFamilies);
    expect(results.whereType<ReaderFontLimitException>().length, 5);
    expect(ReaderFonts.debugLoadedFamilies, ReaderFonts.maxFamilies);
  });

  test(
    'a failed request cannot evict a newer request for the same path',
    () async {
      final firstGate = Completer<void>();
      final secondGate = Completer<void>();
      var calls = 0;
      ReaderFonts.debugLoader = (path) {
        calls++;
        if (path == '/a.ttf' && calls == 1) return firstGate.future;
        return secondGate.future;
      };
      final first = ReaderFonts.load(
        '/a.ttf',
      ).then<Object?>((family) => family).catchError((Object error) => error);
      final others = <Future<Object?>>[
        for (var i = 0; i < ReaderFonts.maxCachedPaths; i++)
          ReaderFonts.load('/other-$i.ttf')
              .then<Object?>((family) => family)
              .catchError((Object error) => error),
      ];
      // /a.ttf was evicted while its first request was still pending.
      final second = ReaderFonts.load(
        '/a.ttf',
      ).then<Object?>((family) => family).catchError((Object error) => error);
      secondGate.complete();
      await second;
      await Future.wait(others);
      firstGate.completeError(const FormatException('first failed'));
      await first;

      final before = ReaderFonts.debugLoadedFamilies;
      await expectLater(ReaderFonts.load('/a.ttf'), isNotNull);
      expect(ReaderFonts.debugLoadedFamilies, before);
    },
  );

  test('cached paths are evicted least-recently-used first', () async {
    ReaderFonts.debugLoader = (_) async {};
    for (var i = 0; i < ReaderFonts.maxCachedPaths; i++) {
      await ReaderFonts.load('/font-$i.ttf');
    }
    // Touch the oldest so it stops being the eviction candidate.
    await ReaderFonts.load('/font-0.ttf');
    await ReaderFonts.load('/font-new.ttf');
    expect(ReaderFonts.debugCachedPaths, ReaderFonts.maxCachedPaths);

    final before = ReaderFonts.debugLoadedFamilies;
    // font-1 was the LRU and must have been evicted: it imports a new family.
    await ReaderFonts.load('/font-1.ttf');
    expect(ReaderFonts.debugLoadedFamilies, before + 1);
    // font-0 is still cached and must not import anything.
    await ReaderFonts.load('/font-0.ttf');
    expect(ReaderFonts.debugLoadedFamilies, before + 1);
  });
}
