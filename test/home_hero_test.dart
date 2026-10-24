import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/search_discovery.dart';
import 'package:fqapp/widgets/home/home_hero.dart';

/// 官方搜索框的热搜词位（`SearchWordDisplayView` + `VerticalFlipper`）与
/// 右上角「分类」入口（`alx.xml` `i_y`）。这里钉住：轮换按
/// `rotate_interval_ms` 走、无词回退静态提示语、loader 失败不冒泡、
/// 分类入口按回调有无占位。框内「识剧」入口已按用户决定删除（2026-10-24）。
void main() {
  Future<void> pump(
    WidgetTester tester,
    Widget child, {
    Size size = const Size(400, 200),
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
  }

  group('cue words', () {
    testWidgets('rotate on the payload interval', (tester) async {
      await pump(
        tester,
        HomeHero(
          onSearch: () {},
          cueLoader: () async =>
              const SearchCue(words: ['热搜词一', '热搜词二'], rotateIntervalMs: 400),
        ),
      );

      // loader 的 future 在微任务里落定，先走一拍再断言首词。
      await tester.pump();

      expect(find.text('热搜词一'), findsOneWidget);
      expect(find.text('热搜词二'), findsNothing);

      // 一个翻页周期 + 淡入淡出动画走完（间隔要长于 300ms 的动画，否则
      // 下一跳会在动画里把词又翻回去；轮换 Timer 常驻，不能用
      // pumpAndSettle——它永远等不到静止）。
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 300));
      // 再走一帧让 AnimatedSwitcher 摘掉淡出完成的旧词。
      await tester.pump(const Duration(milliseconds: 1));
      expect(find.text('热搜词二'), findsOneWidget);
      expect(find.text('热搜词一'), findsNothing);
    });

    testWidgets('keep the static hint when the cue is empty', (tester) async {
      await pump(
        tester,
        HomeHero(onSearch: () {}, cueLoader: () async => SearchCue.empty),
      );
      await tester.pumpAndSettle();

      expect(find.text(HomeHero.searchHint), findsOneWidget);
    });

    testWidgets('keep the static hint when the loader throws', (tester) async {
      await pump(
        tester,
        HomeHero(
          onSearch: () {},
          cueLoader: () async => throw StateError('offline'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text(HomeHero.searchHint), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('no loader means no rotation at all', (tester) async {
      await pump(
        tester,
        const HomeHero(onSearch: _Noop._),
      );
      await tester.pump(const Duration(seconds: 30));

      expect(find.text(HomeHero.searchHint), findsOneWidget);
    });
  });

  group('category entry (alx.xml i_y)', () {
    testWidgets('renders beside the search bar and reports taps', (
      tester,
    ) async {
      var taps = 0;
      await pump(tester, HomeHero(onSearch: () {}, onCategory: () => taps++));

      // 文案与图标在搜索行右侧（`i_y`：14dp 图标 + 14sp「分类」）。
      expect(find.text(HomeHero.categoryLabel), findsOneWidget);
      expect(
        tester.getTopRight(find.byKey(const Key('home_category_button'))).dx,
        greaterThan(
          tester.getTopRight(find.byKey(const Key('home_search_button'))).dx,
        ),
      );

      await tester.tap(find.byKey(const Key('home_category_button')));
      await tester.pump();
      expect(taps, 1);
    });

    testWidgets('takes no space without a callback (i_y gone)', (tester) async {
      await pump(
        tester,
        const HomeHero(onSearch: _Noop._),
      );

      expect(find.text(HomeHero.categoryLabel), findsNothing);
    });
  });

  group('SearchCue payload', () {
    test('reads data_v1 words and rotate_interval_ms', () {
      final cue = SearchCue.fromPayload(const {
        'code': 0,
        'rotate_interval_ms': 8000,
        'data_v1': [
          {'display_text': '词一', 'text': 'ignored'},
          {'display_text_v2': '词二优先'},
          {'text': '词三兜底'},
          {'display_text': ''},
          {'display_text': '词一'},
        ],
      });
      expect(cue.words, ['词一', '词二优先', '词三兜底']);
      expect(cue.rotateIntervalMs, 8000);
    });

    test('falls back to the default interval and empty on bad payloads', () {
      expect(SearchCue.empty.isEmpty, isTrue);
      expect(SearchCue.empty.rotateIntervalMs, SearchCue.defaultIntervalMs);
      expect(
        SearchCue.fromPayload(const {'code': 1, 'data_v1': []}).isEmpty,
        isTrue,
      );
      expect(
        SearchCue.fromPayload(const {
          'data_v1': [],
          'rotate_interval_ms': 0,
        }).rotateIntervalMs,
        SearchCue.defaultIntervalMs,
      );
    });
  });
}

class _Noop {
  static void _() {}
}
