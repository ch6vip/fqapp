import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/home_page.dart';
import 'package:fqapp/pages/home_provider.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:fqapp/widgets/home/home_hero.dart';
import 'package:fqapp/widgets/home/home_shelf.dart';

/// 书架版式在页面层的回归：推荐页只画书、主视觉不重复、追加失败可重试。
///
/// 版式细节（卡片三行字、榜单名次、分区头）在 home_card_test.dart，这里只
/// 钉住页面组合与网络行为。
void main() {
  testWidgets('推荐页只画书：混排里的短剧不进书架', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    MediaItem item(String id, String title, String kind) => MediaItem(
      id: id,
      title: title,
      cover: '',
      author: '',
      badge: '',
      ep: '',
      kind: kind,
    );
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
                    items: [
                      item('v1', '短剧一', 'video'),
                      item('b1', '小说一', 'book'),
                    ],
                    nextOffset: null,
                    sessionId: null,
                  ),
              searchLoader: (query, {int page = 1}) async => const [],
            ),
          ),
        ],
        child: const MaterialApp(home: HomePage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('小说一'), findsOneWidget);
    expect(find.text('短剧一'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('没有阅读史就没有继续阅读行，书全部落在网格里', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    MediaItem book(String id, String title, {String intro = ''}) => MediaItem(
      id: id,
      title: title,
      cover: '',
      author: '',
      badge: '',
      ep: '',
      kind: 'book',
      intro: intro,
    );
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
                    items: [
                      book('b1', '第一本'),
                      book('b2', '带简介的书', intro: '这段简介用来占住编辑位。'),
                    ],
                    nextOffset: null,
                    sessionId: null,
                  ),
              searchLoader: (query, {int page = 1}) async => const [],
            ),
          ),
        ],
        child: const MaterialApp(home: HomePage()),
      ),
    );
    await tester.pumpAndSettle();

    // 没有主视觉、也没有「今日之选」：两本书都按普通卡片落进网格。
    expect(find.text('今日之选'), findsNothing);
    expect(find.text('继续阅读'), findsNothing);
    expect(find.text('这段简介用来占住编辑位。'), findsNothing);
    expect(find.text('带简介的书'), findsOneWidget);
    expect(find.text('第一本'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('追加失败给可点的重试，重试能继续拉下一页', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    MediaItem book(String id, String title) => MediaItem(
      id: id,
      title: title,
      cover: '',
      author: '',
      badge: '',
      ep: '',
      kind: 'book',
    );
    var failNext = true;
    var nextCalls = 0;
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          homeProvider.overrideWith(
            () => HomeNotifier(
              homepageLoader:
                  ({int tabType = 2, int offset = 0, String? sessionId}) async {
                    if (tabType != 2) {
                      return const HomepagePage(
                        items: [],
                        nextOffset: null,
                        sessionId: null,
                      );
                    }
                    if (offset == 0) {
                      return HomepagePage(
                        items: [
                          for (var i = 0; i < 8; i++) book('b$i', '小说 $i'),
                        ],
                        nextOffset: 1,
                        sessionId: 's',
                      );
                    }
                    nextCalls++;
                    if (failNext) throw ApiException('网络开小差了');
                    return HomepagePage(
                      items: [book('later', '后来之书')],
                      nextOffset: null,
                      sessionId: 's',
                    );
                  },
              searchLoader: (query, {int page = 1}) async => const [],
            ),
          ),
        ],
        child: MaterialApp(home: HomePage(scrollController: controller)),
      ),
    );
    await tester.pumpAndSettle();

    // 滚到底触发追加；这一页会失败。
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(nextCalls, 1);
    expect(find.text('加载失败，点击重试'), findsOneWidget);

    failNext = false;
    await tester.tap(find.text('加载失败，点击重试'));
    await tester.pumpAndSettle();
    expect(nextCalls, 2);
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(find.text('后来之书'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('桌面宽窗铺满窗口，不再居中留出固定空白', (tester) async {
    // 这条守的是页面级宽度上限：原先桌面固定吃 1440，2560 的窗口里内容只占
    // 一半多，两侧各空 560dp。
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await tester.binding.setSurfaceSize(const Size(2560, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    MediaItem book(int index) => MediaItem(
      id: 'b$index',
      title: '书 $index',
      cover: '',
      author: '',
      badge: '',
      ep: '',
      kind: 'book',
    );
    try {
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
                      items: [for (var i = 0; i < 30; i++) book(i)],
                      nextOffset: null,
                      sessionId: null,
                    ),
                searchLoader: (query, {int page = 1}) async => const [],
              ),
            ),
          ],
          child: const MaterialApp(home: HomePage()),
        ),
      );
      await tester.pumpAndSettle();

      // 页面本身不再被夹住：宽度等于窗口宽度。
      expect(tester.getSize(find.byType(HomePage)).width, 2560);
      // 网格按短剧那套口径铺列（一格 190dp），封在 9 列。固定断点时代这里只有
      // 5 列；按卡宽反推而不封顶的话会给 13 列，一屏四十本小书扫起来只剩色块。
      final grid = tester.widget<SliverGrid>(find.byType(SliverGrid).first);
      final columns =
          (grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
              .crossAxisCount;
      expect(columns, 9);
      // 列数封顶后多出来的宽度归卡片：一张卡 270dp 上下，是默认窗口的 1.4 倍。
      expect(
        homeShelfCardWidth(
          tester.element(find.byType(HomePage)),
          2560 - homeGutter * 2,
        ),
        greaterThan(260),
      );
      // 搜索行另有上限，不会撑成一条 2500 宽的灰带。
      expect(
        tester.getSize(find.byKey(const Key('home_search_button'))).width,
        lessThan(HomeHero.maxToolbarWidth),
      );
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
