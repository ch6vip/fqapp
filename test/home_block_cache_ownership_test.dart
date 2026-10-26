import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/home_cell.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/home_page.dart';
import 'package:fqapp/pages/home_provider.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:fqapp/services/home_feed_cache.dart';

/// 区块管线的缓存必须跟着「这份 cells 的归属」失效。
///
/// 真机日志钉住的形状：`整页落地 tab=5 … cells=337` 紧接一行
/// `渲染 blocks tab=5 cells=337` —— 听书的 `337` 没有任何渲染器，却被区块
/// 管线画了出来。根因是 `_blockBodySlivers` 把 `_blocksCells` 先改成这份
/// 列表、一个块都没渲染出来时却**没有清掉 `_blocksBody`**：下一次带同一份
/// 列表实例的重建（任何一次 `copyWith`，比如翻页标志翻转）就命中缓存，把
/// 上一个分类建好的「排行榜 + 猜你喜欢」原样交回去 —— 表现就是「听书第二次
/// 加载变成推荐/小说」。
void main() {
  setUp(() => HomeFeedCache.hiveReady = false);
  tearDown(() => HomeFeedCache.hiveReady = false);

  testWidgets('听书不再捡回推荐那套区块', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 2600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

    MediaItem card(String id, String title, String kind) => MediaItem(
      id: id,
      title: title,
      cover: '',
      author: '',
      badge: '',
      ep: '',
      kind: kind,
    );

    late HomeNotifier notifier;

    Future<HomepagePage> loadPage({
      int tabType = 2,
      int offset = 0,
      String? sessionId,
    }) async {
      if (tabType == 2) {
        // 推荐：384 → 385 的卡片流，真机上还会带 511 排行榜。
        return HomepagePage(
          items: [card('rec-1', '推荐书', 'book')],
          cells: [
            HomeCell(
              showType: 384,
              name: '猜你喜欢',
              id: '',
              style: const {},
              items: const [],
              children: [
                HomeCell(
                  showType: 385,
                  name: '',
                  id: '',
                  style: const {},
                  items: [card('rec-1', '推荐书', 'book')],
                  children: const [],
                ),
              ],
            ),
          ],
          nextOffset: null,
          sessionId: null,
          answeredTabType: 2,
          tabScoped: true,
        );
      }
      // 听书：337 这一族没有任何渲染器，只能走卡片网格。
      return HomepagePage(
        items: [card('a-1', '听书卡', 'audio')],
        cells: const [
          HomeCell(
            showType: 337,
            name: '爆款网文听听看',
            id: '',
            style: {},
            items: [],
            children: [],
          ),
        ],
        nextOffset: 12,
        sessionId: 'session',
        answeredTabType: 5,
        tabScoped: true,
      );
    }

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          homeProvider.overrideWith(() {
            notifier = HomeNotifier(
              usesLocalTabs: true,
              homepageLoader: loadPage,
              searchLoader: (query, {int page = 1}) async => const [],
            );
            return notifier;
          }),
        ],
        child: const MaterialApp(home: HomePage()),
      ),
    );

    // 推荐先画出它自己的卡片流，区块管线因此缓存了一份 body。
    await tester.pumpAndSettle();
    expect(find.text('推荐书'), findsWidgets);

    // 切到听书：337 没有渲染器，必须落到卡片网格。
    await tester.tap(find.byKey(const ValueKey('home_category_5')));
    await tester.pumpAndSettle();
    expect(find.text('听书卡'), findsWidgets);
    expect(find.text('推荐书'), findsNothing);

    // 任何一次带着「同一份 cells 实例」的重建：翻页标志翻转就是最典型的一次。
    // 修好之前，这一步会命中区块缓存、把推荐那套 body 交回来。
    notifier.loadMore();
    await tester.pump();
    expect(
      find.text('推荐书'),
      findsNothing,
      reason: '听书的 cells 渲染不出区块时，缓存必须作废，不能捡回推荐那套',
    );
    expect(find.text('听书卡'), findsWidgets);
  });
}
