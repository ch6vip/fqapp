import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/home_page.dart';
import 'package:fqapp/pages/home_provider.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:fqapp/widgets/home/home_feed_states.dart';
import 'package:fqapp/widgets/home/home_hero.dart';
import 'package:fqapp/widgets/home/home_skeleton.dart';
import 'package:fqapp/widgets/tab_swipe_area.dart';

/// 首页横滑切分类时「像短剧那样原地换一屏」。
///
/// 短剧页的顶栏在滚动视图外面，切频道只换内容，所以观感是「换了一屏」；首页
/// 的搜索行（hero）和分类条都在同一个滚动视图里，以前切分类还会把视图跳回
/// 别处、把还没进过的分类铺成满屏脉冲骨架——三件事叠起来就是用户说的「整页
/// 重新加载了一个界面」。
///
/// 现在的约定：
/// * 搜索行没滚出屏幕时切分类：位置一点不动；
/// * 已经滚过搜索行：只把内容区摆回第一行（分类条吸顶处），不把搜索行带回来；
/// * 切分类不铺整页骨架，用一行安静提示；冷启动首载才铺骨架。
void main() {
  const surface = Size(400, 800);
  const itemsPerTabType = {2: 40, 8: 6, 24: 12, 5: 30};
  const kindByTabType = {2: 'book', 8: 'video', 24: 'manju', 5: 'audio'};

  MediaItem item(String prefix, int index, String kind) => MediaItem(
    id: '$prefix$index',
    title: '$prefix 作品 $index',
    cover: '',
    author: '',
    badge: '',
    ep: '',
    kind: kind,
  );

  Future<void> pumpHome(
    WidgetTester tester, {

    /// 打开后每个分类都还有下一页：用来观察「切分类本身会不会多拉一页」。
    bool paged = false,
    List<String>? requests,
    Map<int, int> itemCounts = itemsPerTabType,

    /// 卡住这个 tab 的请求，用来观察加载中那一帧画的是什么。
    Completer<void>? gate,
    int gatedTabType = 8,
  }) async {
    await tester.binding.setSurfaceSize(surface);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          homeProvider.overrideWith(
            () => HomeNotifier(
              homepageLoader:
                  ({int tabType = 2, int offset = 0, String? sessionId}) async {
                    requests?.add('$tabType@$offset');
                    if (gate != null && tabType == gatedTabType) {
                      await gate.future;
                    }
                    final kind = kindByTabType[tabType] ?? 'book';
                    return HomepagePage(
                      items: [
                        for (var i = 0; i < (itemCounts[tabType] ?? 10); i++)
                          item('$tabType-', i, kind),
                      ],
                      nextOffset: paged ? offset + 40 : null,
                      sessionId: null,
                    );
                  },
              searchLoader: (query, {int page = 1}) async => [],
            ),
          ),
        ],
        child: const MaterialApp(home: HomePage()),
      ),
    );
    // 骨架屏是循环动画，不能用 pumpAndSettle。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  ScrollPosition positionOf(WidgetTester tester) => tester
      .widget<CustomScrollView>(find.byKey(const Key('home_feed')))
      .controller!
      .position;

  /// 分类条吸顶时内容区的第一行：搜索行的高度。
  double heroHeight(WidgetTester tester) =>
      tester.getSize(find.byType(HomeHero)).height;

  /// 横滑切一个分类，并推进到迎入动画结束。
  Future<void> swipeTab(WidgetTester tester, double dx) async {
    await tester.drag(find.byKey(const Key('home_feed')), Offset(dx, 0));
    for (var frame = 0; frame < 24; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  Future<void> scrollDown(WidgetTester tester, double dy) async {
    await tester.drag(find.byKey(const Key('home_feed')), Offset(0, dy));
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('横滑时搜索行和分类条不跟着走，只有内容在滑', (tester) async {
    await pumpHome(tester);
    final hero = tester.getRect(find.byType(HomeHero));
    final firstTab = tester.getRect(
      find.byKey(const ValueKey('home_category_0')),
    );

    await tester.drag(
      find.byKey(const Key('home_feed')),
      const Offset(-260, 0),
    );
    for (var frame = 1; frame <= 20; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      // 顶栏属于「页面」，不属于「内容」：它跟着动的话，屏幕上就是整页
      // 被换掉（短剧页的顶栏在滑动区外面，所以从来不这样）。
      expect(
        tester.getRect(find.byType(HomeHero)).left,
        hero.left,
        reason: '第 $frame 帧：搜索行跟着横滑走了',
      );
      expect(
        tester.getRect(find.byKey(const ValueKey('home_category_0'))).left,
        firstTab.left,
        reason: '第 $frame 帧：分类条跟着横滑走了',
      );
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('拖动时缺口里铺邻页内容，滚动视口不再裁掉钉住的顶栏', (tester) async {
    await pumpHome(tester);
    final feed = find.byKey(const Key('home_feed'));
    expect(
      tester.widget<CustomScrollView>(feed).clipBehavior,
      Clip.none,
      reason: '顶栏被反向位移画到视口外，视口不能再裁；裁剪交给 TabSwipeArea',
    );
    expect(
      tester.widget<TabSwipeArea>(find.byType(TabSwipeArea)).isolateChild,
      isFalse,
      reason: '位移层套了重绘边界，钉住的顶栏会被栅格裁掉',
    );

    final gesture = await tester.startGesture(tester.getCenter(feed));
    await gesture.moveBy(const Offset(-100, 0));
    await tester.pump();

    // 小说分类还没进过：拖动中铺的是它的骨架，而不是一块底色。
    expect(find.byType(HomeSkeleton), findsOneWidget, reason: '拖动时缺口里应当出现邻页内容');

    await gesture.up();
    for (var frame = 0; frame < 30; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(find.byType(HomeSkeleton), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('搜索行还在屏幕上时切分类：位置一点不动', (tester) async {
    await pumpHome(tester);
    final position = positionOf(tester);
    expect(position.pixels, 0);

    await swipeTab(tester, -260);

    // 换内容，但视口原地不动，搜索行仍然在。
    expect(position.pixels, 0);
    expect(tester.getRect(find.byType(HomeHero)).top, greaterThanOrEqualTo(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('已经滚过搜索行时切分类：内容区回到第一行，搜索行不被带回来', (tester) async {
    await pumpHome(tester);
    final position = positionOf(tester);
    final pin = heroHeight(tester);

    await scrollDown(tester, -600);
    expect(position.pixels, greaterThan(pin));

    await swipeTab(tester, -260);

    // 内容区回到分类条下方第一行 = 搜索行刚好滚出（pixels == 搜索行高度），
    // 而不是被拉回顶部（那会是 0，搜索行重新出现，也就是「整页重载」的感觉）。
    expect(pin, greaterThan(0));
    expect(position.pixels, pin);
    expect(tester.takeException(), isNull);
  });

  testWidgets('切到还没进过的分类：不铺整页骨架，只用一行提示', (tester) async {
    final gate = Completer<void>();
    addTearDown(() => gate.isCompleted ? null : gate.complete());
    await pumpHome(tester, gate: gate);

    // 推荐 → 小说（同 tab_type 的缓存）→ 短剧（未进过、请求被卡住）。
    await swipeTab(tester, -260);
    await swipeTab(tester, -260);

    expect(find.byType(HomeSkeleton), findsNothing, reason: '切分类不该铺整页骨架');
    expect(find.byType(HomeFeedLoading), findsOneWidget);
    expect(find.text('正在刷新内容'), findsOneWidget);

    gate.complete();
    for (var frame = 0; frame < 30; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(find.byType(HomeFeedLoading), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('切回有缓存的分类只换内容，不顺带拉下一页', (tester) async {
    final requests = <String>[];
    await pumpHome(tester, paged: true, requests: requests);
    final position = positionOf(tester);

    await scrollDown(tester, -600);
    await swipeTab(tester, -260);
    await scrollDown(tester, -600);
    final kept = position.pixels;
    expect(kept, greaterThan(400));

    // 去短剧（内容短），再回来：位置会被新内容的长度钳住，但不该多发请求。
    await swipeTab(tester, -260);
    final before = requests.length;
    await swipeTab(tester, 260);
    expect(
      requests.skip(before).toList(),
      isEmpty,
      reason: '切回缓存分类不该发请求：${requests.skip(before).toList()}',
    );
    expect(tester.takeException(), isNull);
  });
}
