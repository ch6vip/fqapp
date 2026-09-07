import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/home_page.dart';
import 'package:fqapp/pages/home_provider.dart';
import 'package:fqapp/services/api_client.dart';

void main() {
  for (final scale in [1.0, 1.8]) {
    testWidgets('search hint fits a narrow phone at text scale $scale', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(320, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            homeProvider.overrideWith(
              () => HomeNotifier(
                homepageLoader:
                    ({
                      int tabType = 2,
                      int offset = 0,
                      String? sessionId,
                    }) async => HomepagePage(
                      items: [],
                      nextOffset: null,
                      sessionId: null,
                    ),
                searchLoader: (query, {int page = 1}) async => [],
              ),
            ),
          ],
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: const HomePage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final hint = find.text('搜索短剧、小说、漫画...');
      expect(hint, findsOneWidget);
      expect(
        tester.getRect(hint).right,
        lessThanOrEqualTo(tester.getRect(find.byIcon(Icons.refresh)).left),
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a long homepage error can be scrolled to retry successfully', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    final message = List.filled(60, '服务暂时不可用，请稍后重试。').join();
    var failing = true;
    var homepageRequests = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          homeProvider.overrideWith(
            () => HomeNotifier(
              homepageLoader:
                  ({int tabType = 2, int offset = 0, String? sessionId}) async {
                    homepageRequests++;
                    if (failing) throw ApiException(message);
                    return HomepagePage(
                      items: [],
                      nextOffset: null,
                      sessionId: null,
                    );
                  },
              searchLoader: (query, {int page = 1}) async {
                if (failing) throw ApiException(message);
                return [];
              },
            ),
          ),
        ],
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.8)),
            child: child!,
          ),
          home: const HomePage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(message), findsOneWidget);
    expect(tester.takeException(), isNull);
    final scrollable = find.descendant(
      of: find.byType(SingleChildScrollView),
      matching: find.byType(Scrollable),
    );
    expect(
      tester.state<ScrollableState>(scrollable).position.maxScrollExtent,
      greaterThan(0),
    );
    expect(find.text('重试').hitTestable(), findsNothing);
    await tester.scrollUntilVisible(
      find.text('重试'),
      400,
      scrollable: scrollable,
    );
    await tester.pumpAndSettle();
    expect(find.text('重试').hitTestable(), findsOneWidget);

    failing = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(homepageRequests, 2);
    expect(find.text('暂无内容'), findsOneWidget);
    expect(find.text(message), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('two initial empty pages continue loading until items appear', (
    tester,
  ) async {
    final offsets = <int>[];
    final secondPage = Completer<HomepagePage>();
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          homeProvider.overrideWith(
            () => HomeNotifier(
              homepageLoader:
                  ({int tabType = 2, int offset = 0, String? sessionId}) async {
                    offsets.add(offset);
                    if (offset == 1) return secondPage.future;
                    return HomepagePage(
                      items: [
                        if (offset == 2)
                          MediaItem(
                            id: 'later-book',
                            title: '后续小说',
                            cover: '',
                            author: '',
                            badge: '',
                            ep: '',
                            kind: 'book',
                          ),
                      ],
                      nextOffset: offset == 0 ? 1 : null,
                      sessionId: 'session',
                    );
                  },
              searchLoader: (query, {int page = 1}) async => [],
            ),
          ),
        ],
        child: const MaterialApp(home: HomePage()),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(offsets, [0, 1]);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('暂无内容'), findsNothing);

    secondPage.complete(
      HomepagePage(items: [], nextOffset: 2, sessionId: 'session'),
    );
    await tester.pump();
    await tester.pump();
    expect(offsets, [0, 1]);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(offsets, [0, 1, 2]);
    expect(find.text('后续小说'), findsOneWidget);
    expect(find.text('暂无内容'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('short fast pages continue loading without a scroll event', (
    tester,
  ) async {
    final offsets = <int>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          homeProvider.overrideWith(
            () => HomeNotifier(
              homepageLoader:
                  ({int tabType = 2, int offset = 0, String? sessionId}) async {
                    offsets.add(offset);
                    return HomepagePage(
                      items: [
                        MediaItem(
                          id: '$offset',
                          title: '小说 $offset',
                          cover: '',
                          author: '',
                          badge: '',
                          ep: '',
                          kind: 'book',
                        ),
                      ],
                      nextOffset: offset < 3 ? offset + 1 : null,
                      sessionId: 'session',
                    );
                  },
              searchLoader: (query, {int page = 1}) async => const [],
            ),
          ),
        ],
        child: const MaterialApp(home: HomePage()),
      ),
    );
    await tester.pumpAndSettle();
    for (var tick = 0; tick < 5; tick++) {
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
    }
    expect(offsets, [0, 1, 2, 3]);
    expect(find.text('小说 3'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });
}
