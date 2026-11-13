import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/home_page.dart';
import 'package:fqapp/pages/home_provider.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:fqapp/widgets/home/home_feed_states.dart';
import 'package:fqapp/widgets/home/home_masthead.dart';
import 'package:fqapp/widgets/home/home_skeleton.dart';
import 'package:fqapp/widgets/tab_swipe_area.dart';

/// Headers stay outside the feed viewport and horizontal transform (#261).
/// Switching categories resets only the feed, without a full-page skeleton.
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

  Future<ScrollController> pumpHome(
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
    // 壳层的控制器跟着「当前页」的 position 走，用来读可见分类的滚动位置。
    final controller = ScrollController();
    addTearDown(controller.dispose);
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
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
        child: MaterialApp(home: HomePage(scrollController: controller)),
      ),
    );
    // 骨架屏是循环动画，不能用 pumpAndSettle。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    return controller;
  }

  ScrollPosition positionOf(ScrollController controller) => controller.position;

  /// 横滑切一个分类：真分页要拖过半页，松手后再等吸附动画。
  Future<void> swipeTab(WidgetTester tester, double dx) async {
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(TabSwipeArea)),
    );
    final steps = 26;
    for (var frame = 0; frame < steps; frame++) {
      await gesture.moveBy(Offset(dx / steps, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    for (var frame = 0; frame < 24; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  Future<void> scrollDown(WidgetTester tester, double dy) async {
    // 在横滑区上竖拖：竖滑由内层 feed 赢下手势，不用去猜当前是哪一页。
    // 分步移动，一次大位移会被 Scrollable 的起手 slop 整段吃掉。
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(TabSwipeArea)),
    );
    const steps = 20;
    for (var frame = 0; frame < steps; frame++) {
      await gesture.moveBy(Offset(0, dy / steps));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('横滑时顶栏和分类条不跟着走，只有内容在滑', (tester) async {
    await pumpHome(tester);
    final hero = tester.getRect(find.byType(HomeMasthead));
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
        tester.getRect(find.byType(HomeMasthead)).left,
        hero.left,
        reason: '第 $frame 帧：顶栏跟着横滑走了',
      );
      expect(
        tester.getRect(find.byKey(const ValueKey('home_category_0'))).left,
        firstTab.left,
        reason: '第 $frame 帧：分类条跟着横滑走了',
      );
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('拖动时缺口里铺邻页内容，顶栏位于裁剪和位移区外', (tester) async {
    await pumpHome(tester);
    final feed = find.byKey(const Key('home_feed'));
    expect(
      tester.widget<CustomScrollView>(feed).clipBehavior,
      Clip.hardEdge,
      reason: '视口只包含内容，可以正常裁剪',
    );
    expect(
      find.ancestor(
        of: find.byType(HomeMasthead),
        matching: find.byType(TabSwipeArea),
      ),
      findsNothing,
    );
    expect(
      find.ancestor(
        of: find.byKey(const ValueKey('home_category_0')),
        matching: find.byType(TabSwipeArea),
      ),
      findsNothing,
    );

    final gesture = await tester.startGesture(tester.getCenter(feed));
    await gesture.moveBy(const Offset(-100, 0));
    await tester.pump();

    // 拖动中邻页是真实页面：视口里已经有第二份 feed，而不是一块底色。
    final pager = tester.widget<PageView>(
      find.byWidgetPredicate(
        (w) => w is PageView && w.scrollDirection == Axis.horizontal,
      ),
    );
    expect(pager.controller!.page, greaterThan(0));
    final feeds = find.byKey(const Key('home_feed'), skipOffstage: false);
    expect(
      feeds.evaluate().length,
      greaterThanOrEqualTo(2),
      reason: '拖动时缺口里应当出现邻页内容',
    );
    final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;
    final incoming = [
      for (final element in feeds.evaluate())
        (element.renderObject! as RenderBox).localToGlobal(Offset.zero).dx,
    ].where((left) => left > 0.5 && left < width);
    expect(incoming, isNotEmpty, reason: '邻页应当已经进入可视区');

    await gesture.up();
    for (var frame = 0; frame < 30; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('顶栏还在屏幕上时切分类：位置一点不动', (tester) async {
    final controller = await pumpHome(tester);
    expect(positionOf(controller).pixels, 0);

    await swipeTab(tester, -260);

    // 换内容，但视口原地不动，顶栏仍然在。
    expect(positionOf(controller).pixels, 0);
    expect(
      tester.getRect(find.byType(HomeMasthead)).top,
      greaterThanOrEqualTo(0),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('每个分类保留自己的滚动位置，顶栏保持固定', (tester) async {
    final controller = await pumpHome(tester);
    final hero = tester.getRect(find.byType(HomeMasthead));

    await scrollDown(tester, -600);
    expect(positionOf(controller).pixels, greaterThan(0));
    final kept = positionOf(controller).pixels;
    expect(tester.getRect(find.byType(HomeMasthead)), hero);

    await swipeTab(tester, -260);
    // 新分类从自己的顶部开始，不要把上一个分类的偏移带过来。
    expect(positionOf(controller).pixels, 0);
    expect(tester.getRect(find.byType(HomeMasthead)), hero);

    await swipeTab(tester, 260);
    // 回到原分类：滚动位置还在（页面子树保活）。
    expect(positionOf(controller).pixels, closeTo(kept, 1));
    expect(tester.getRect(find.byType(HomeMasthead)), hero);
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
    final controller = await pumpHome(tester, paged: true, requests: requests);

    await scrollDown(tester, -600);
    final kept = positionOf(controller).pixels;
    expect(kept, greaterThan(400));

    // 先去下一个分类（它自己该拉一次），再回来：回来时不该再发请求，
    // 滚动位置按保活的页面恢复。
    await swipeTab(tester, -260);
    final before = requests.length;
    await swipeTab(tester, 260);
    expect(
      requests.skip(before).toList(),
      isEmpty,
      reason: '切回缓存分类不该发请求：${requests.skip(before).toList()}',
    );
    expect(positionOf(controller).pixels, closeTo(kept, 1));
    expect(tester.takeException(), isNull);
  });
}
