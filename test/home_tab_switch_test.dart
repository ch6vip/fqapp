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

    // 小说分类还没进过：拖动中铺的是它的骨架，而不是一块底色。
    expect(find.byType(HomeSkeleton), findsOneWidget, reason: '拖动时缺口里应当出现邻页内容');

    await gesture.up();
    for (var frame = 0; frame < 30; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(find.byType(HomeSkeleton), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('顶栏还在屏幕上时切分类：位置一点不动', (tester) async {
    await pumpHome(tester);
    final position = positionOf(tester);
    expect(position.pixels, 0);

    await swipeTab(tester, -260);

    // 换内容，但视口原地不动，顶栏仍然在。
    expect(position.pixels, 0);
    expect(tester.getRect(find.byType(HomeMasthead)).top, greaterThanOrEqualTo(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('滚动内容后切分类：内容回到首行，顶栏保持固定', (tester) async {
    await pumpHome(tester);
    final position = positionOf(tester);
    final hero = tester.getRect(find.byType(HomeMasthead));

    await scrollDown(tester, -600);
    expect(position.pixels, greaterThan(0));
    expect(tester.getRect(find.byType(HomeMasthead)), hero);

    await swipeTab(tester, -260);

    expect(position.pixels, 0);
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
