import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/widgets/home/home_rank_shelf.dart';

/// The archive shelf measures itself against the vertical viewport and the
/// ambient text scaler, then paints the spines in unscaled paint units. These
/// tests pin that sizing contract so short screens, large text and flat
/// degradation cannot push the shelf past the feed viewport.
void main() {
  setUp(() => HomeRankShelf.degraded = false);
  tearDown(() => HomeRankShelf.degraded = false);

  MediaItem book(String id, String title) => MediaItem(
    id: id,
    title: title,
    cover: '',
    author: '',
    badge: '',
    ep: '',
    kind: 'book',
    readCount: '',
    creationStatus: -1,
  );

  /// Exposes a context below [MediaQuery] — and, when [viewportHeight] is set,
  /// below a vertical [Scrollable] — then asks the shelf for its reserved
  /// height in that environment.
  Future<double> measure(
    WidgetTester tester, {
    required Size surface,
    TextScaler scaler = TextScaler.noScaling,
    double? viewportHeight,
  }) async {
    await tester.binding.setSurfaceSize(surface);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    late BuildContext captured;
    Widget child = Builder(
      builder: (context) {
        captured = context;
        return const SizedBox.shrink();
      },
    );
    if (viewportHeight != null) {
      child = SizedBox(
        height: viewportHeight,
        child: SingleChildScrollView(child: child),
      );
    }
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(size: surface, textScaler: scaler),
            child: Scaffold(body: child),
          ),
        ),
      ),
    );
    await tester.pump();
    return HomeRankShelf.loadingHeight(captured, 400);
  }

  group('archive shelf geometry', () {
    testWidgets(
      'a short viewport shrinks the shelf without losing the controls',
      (tester) async {
        final short = await measure(tester, surface: const Size(400, 500));
        final tall = await measure(tester, surface: const Size(400, 900));

        expect(short, greaterThan(0));
        expect(short, lessThan(500));
        expect(short, lessThan(tall - 50));
      },
    );

    testWidgets('a bounded vertical scroll viewport caps the shelf height', (
      tester,
    ) async {
      final unbounded = await measure(tester, surface: const Size(400, 900));
      final bounded = await measure(
        tester,
        surface: const Size(400, 900),
        viewportHeight: 400,
      );

      expect(bounded, lessThan(unbounded));
      expect(bounded, lessThan(900));
    });

    testWidgets(
      'large text scaling grows the controls but stays in the viewport',
      (tester) async {
        final normal = await measure(
          tester,
          surface: const Size(400, 900),
          scaler: const TextScaler.linear(1),
        );
        final large = await measure(
          tester,
          surface: const Size(400, 900),
          scaler: const TextScaler.linear(1.8),
        );

        expect(large, greaterThan(normal));
        expect(large, lessThan(900));

        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: const TextScaler.linear(1.8)),
                child: Scaffold(
                  body: HomeRankShelf(
                    books: [book('r1', '榜书一'), book('r2', '榜书二')],
                    onOpen: (_) {},
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(find.text('榜书一'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'degraded mode reserves the flat height and renders the flat rail',
      (tester) async {
        HomeRankShelf.degraded = true;
        final degraded = await measure(tester, surface: const Size(400, 900));
        HomeRankShelf.degraded = false;
        final normal = await measure(tester, surface: const Size(400, 900));
        expect(degraded, lessThan(normal));

        HomeRankShelf.degraded = true;
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: HomeRankShelf(
                books: [book('r1', '榜书一'), book('r2', '榜书二')],
                onOpen: (_) {},
              ),
            ),
          ),
        );
        await tester.pump();
        expect(find.byKey(const Key('home_rank_flat_rail')), findsOneWidget);
        expect(find.text('榜书一'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('the pager stays on screen in a short viewport', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(400, 500));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(size: const Size(400, 500)),
              child: Scaffold(
                body: HomeRankShelf(
                  books: [book('r1', '榜书一'), book('r2', '榜书二')],
                  onOpen: (_) {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('榜书一'), findsOneWidget);
      final pager = tester.getRect(find.byKey(const Key('home_rank_next')));
      expect(pager.bottom, lessThan(500));
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'large text in a short viewport still lets the pager scroll clear of the dock',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(400, 500));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  size: const Size(400, 500),
                  textScaler: const TextScaler.linear(1.3),
                  padding: const EdgeInsets.only(bottom: 72),
                ),
                child: Scaffold(
                  body: Stack(
                    children: [
                      Positioned.fill(
                        child: SingleChildScrollView(
                          key: const Key('p0_feed'),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const SizedBox(height: 220),
                              HomeRankShelf(
                                books: [book('r1', '榜书一'), book('r2', '榜书二')],
                                onOpen: (_) {},
                              ),
                              const SizedBox(height: 800),
                            ],
                          ),
                        ),
                      ),
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: SizedBox(key: const Key('p0_dock'), height: 72),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        final dock = tester.getRect(find.byKey(const Key('p0_dock')));
        var clear = false;
        for (var i = 0; i < 6; i++) {
          final next = tester.getRect(find.byKey(const Key('home_rank_next')));
          if (next.bottom <= dock.top) {
            clear = true;
            break;
          }
          await tester.drag(
            find.byKey(const Key('p0_feed')),
            const Offset(0, -160),
          );
          await tester.pump();
        }
        // MuMu 实测：首屏与滚动中间态翻页器会落在悬浮 dock 区域内，继续
        // 滚动即可脱离。这里钉住「滚动后可命中」，不要求首屏不重叠。
        expect(clear, isTrue, reason: 'pager never scrolled clear of the dock');

        await tester.tap(find.byKey(const Key('home_rank_next')));
        await tester.pumpAndSettle();
        expect(find.text('02 / 02'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  });
}
