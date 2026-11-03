import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/widgets/tab_swipe_area.dart';

/// 横滑换标签那一帧的观感。
///
/// 用户反馈「短剧切得对，但不流畅」：切换链是「送出 → 换标签 → 迎入」，而
/// 换完标签那一帧曾经还停在**出场**位移上（-34% 屏宽），下一帧才跳到 +34%
/// 迎入，屏幕上就是一次 68% 屏宽的生硬横跳。这里把每一帧的「标签下标 + 位移」
/// 都记下来，断言新内容从出现的第一帧起就画在迎入侧。
void main() {
  /// 400 宽的视口：出场 / 迎入位移各是 136（[TabSwipeArea.exitFraction]）。
  const surface = Size(400, 800);

  Widget host(ValueNotifier<int> index) => MaterialApp(
    home: Scaffold(
      body: ValueListenableBuilder<int>(
        valueListenable: index,
        builder: (context, value, _) => TabSwipeArea(
          index: value,
          count: 3,
          onSelect: (next) => index.value = next,
          child: Center(
            child: Text('page $value', key: ValueKey('page-$value')),
          ),
        ),
      ),
    ),
  );

  double translateX(WidgetTester tester) {
    final transform = tester.widget<Transform>(
      find
          .descendant(
            of: find.byType(TabSwipeArea),
            matching: find.byType(Transform),
          )
          .first,
    );
    return transform.transform.getTranslation().x;
  }

  testWidgets('换标签的那一帧就把新内容摆在迎入侧，不在出场位移上多停一帧', (tester) async {
    await tester.binding.setSurfaceSize(surface);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final index = ValueNotifier<int>(0);
    addTearDown(index.dispose);
    await tester.pumpWidget(host(index));

    await tester.drag(find.byType(TabSwipeArea), const Offset(-260, 0));

    var switchedFrame = -1;
    for (var frame = 1; frame <= 40; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      final dx = translateX(tester);
      if (index.value == 1) {
        if (switchedFrame < 0) switchedFrame = frame;
        // 左滑切下一个：新内容只能从 +136 那侧迎进来。负值意味着这一帧画的
        // 还是出场位移，屏幕上会看到一次横跳。
        expect(
          dx,
          greaterThanOrEqualTo(0),
          reason: '第 $frame 帧：标签已是 1，位移却是 $dx（出场侧）',
        );
      }
    }
    expect(switchedFrame, greaterThan(0));
    expect(index.value, 1);
    expect(find.byKey(const ValueKey('page-1')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('右滑切上一个时，新内容同样直接从入场侧出现', (tester) async {
    await tester.binding.setSurfaceSize(surface);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final index = ValueNotifier<int>(2);
    addTearDown(index.dispose);
    await tester.pumpWidget(host(index));

    await tester.drag(find.byType(TabSwipeArea), const Offset(260, 0));

    for (var frame = 1; frame <= 40; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (index.value != 1) continue;
      // 右滑的前一页从左侧（-136）迎进来。
      expect(
        translateX(tester),
        lessThanOrEqualTo(0),
        reason: '第 $frame 帧：标签已是 1，位移却停在 +136（出场侧）',
      );
    }
    expect(index.value, 1);
    expect(tester.takeException(), isNull);
  });

  /// 顶栏在滑动区**里面**的宿主（首页的形状）：顶栏套 `SwipeStationary` 钉住，
  /// 下方内容跟着横滑走。
  Widget hostWithHeader(ValueNotifier<int> index) => MaterialApp(
    home: Scaffold(
      body: ValueListenableBuilder<int>(
        valueListenable: index,
        builder: (context, value, _) => TabSwipeArea(
          index: value,
          count: 3,
          onSelect: (next) => index.value = next,
          // 与首页一致：顶栏在滚动视口里反向位移，不能套重绘边界。
          isolateChild: false,
          child: Column(
            children: [
              SwipeStationary(
                child: SizedBox(
                  height: 48,
                  child: Center(child: Text('header')),
                ),
              ),
              Expanded(child: Text('page $value')),
            ],
          ),
        ),
      ),
    ),
  );

  testWidgets('包在 SwipeStationary 里的顶栏钉在屏幕上，不跟着横滑', (tester) async {
    await tester.binding.setSurfaceSize(surface);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final index = ValueNotifier<int>(0);
    addTearDown(index.dispose);
    await tester.pumpWidget(hostWithHeader(index));

    final before = tester.getRect(find.text('header'));
    await tester.drag(find.byType(TabSwipeArea), const Offset(-260, 0));

    var moved = false;
    for (var frame = 1; frame <= 30; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (translateX(tester) != 0) moved = true;
      final rect = tester.getRect(find.text('header'));
      expect(
        rect.left,
        before.left,
        reason: '第 $frame 帧：顶栏跟着横滑走了，位移是 ${translateX(tester)}',
      );
      expect(rect.top, before.top, reason: '第 $frame 帧：顶栏上下跳了');
    }
    // 内容确实滑过：否则上面那些断言什么都没验证。
    expect(moved, isTrue);
    expect(index.value, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('迎入动画期间再滑一次不该被吞掉（快速连滑）', (tester) async {
    await tester.binding.setSurfaceSize(surface);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final index = ValueNotifier<int>(0);
    addTearDown(index.dispose);
    await tester.pumpWidget(host(index));
    final area = find.byType(TabSwipeArea);

    await tester.drag(area, const Offset(-260, 0));
    // 出场 110ms 走完、标签已经换过来，此刻正处在迎入期间（还剩约 190ms）。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 130));
    expect(index.value, 1);

    await tester.drag(area, const Offset(-260, 0));
    for (var frame = 0; frame < 40; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(index.value, 2, reason: '迎入期间的手势被丢弃了：连滑两下只切了一页');
    expect(tester.takeException(), isNull);
  });

  testWidgets('系统「移除动画」开启时，切标签不该有任何位移', (tester) async {
    await tester.binding.setSurfaceSize(surface);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final index = ValueNotifier<int>(0);
    addTearDown(index.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: Scaffold(
              body: ValueListenableBuilder<int>(
                valueListenable: index,
                builder: (context, value, _) => TabSwipeArea(
                  index: value,
                  count: 3,
                  onSelect: (next) => index.value = next,
                  child: Center(child: Text('page $value')),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.drag(find.byType(TabSwipeArea), const Offset(-260, 0));
    for (var frame = 1; frame <= 12; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(translateX(tester), 0, reason: '第 $frame 帧：关了动画还在位移，屏幕上是一次闪现');
    }
    expect(index.value, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('系统「移除动画」+ 点标签切换：同样不该有任何位移', (tester) async {
    await tester.binding.setSurfaceSize(surface);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final index = ValueNotifier<int>(0);
    addTearDown(index.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: Scaffold(body: host(index)),
          ),
        ),
      ),
    );

    // 点标签那条路径：父级直接换 index，没有手势，走的是 didUpdateWidget。
    index.value = 1;
    for (var frame = 1; frame <= 8; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(translateX(tester), 0, reason: '第 $frame 帧：点标签切换在关闭动画时还在位移');
    }
    expect(find.byKey(const ValueKey('page-1')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('反向位移上面不许再套重绘边界（真机顶栏被裁的根因）', (tester) async {
    await tester.binding.setSurfaceSize(surface);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final index = ValueNotifier<int>(0);
    addTearDown(index.dispose);
    await tester.pumpWidget(hostWithHeader(index));

    final counter = find.descendant(
      of: find.byType(SwipeStationary),
      matching: find.byType(Transform),
    );
    expect(counter, findsOneWidget);

    // 反向位移与 SwipeStationary 之间不许插重绘边界：边界的栅格只有它自己 size
    // 那么大，反向位移把内容推出这块范围就直接不画——真机上搜索行右半截、「分类」
    // 按钮、末位标签一起消失，露出黑色画布压在顶栏上（2026-11-02 实拍）。
    //
    // 不能数「上面一共几层边界」：MaterialApp / Scaffold 自己就会插边界（实测 3
    // 层），要锁的是这一层的位置，所以走到 SwipeStationary 就停。
    //
    // 为什么不断言像素：flutter_test 的软件光栅不复现这个裁切（破坏版截图仍然
    // 「通过」），只有真机看得出来，所以这里锁住它的成因。
    var boundaryInside = false;
    tester.element(counter.first).visitAncestorElements((ancestor) {
      if (ancestor.widget is SwipeStationary) return false;
      if (ancestor.widget is RepaintBoundary) {
        boundaryInside = true;
        return false;
      }
      return true;
    });
    expect(boundaryInside, isFalse, reason: '反向位移外面套了一层重绘边界，顶栏会被它裁掉');
    expect(tester.takeException(), isNull);
  });

  testWidgets('位移层外面不许套重绘边界（栅格只认自己的 bounds，会把顶栏裁掉）', (tester) async {
    await tester.binding.setSurfaceSize(surface);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final index = ValueNotifier<int>(0);
    addTearDown(index.dispose);
    await tester.pumpWidget(hostWithHeader(index));

    // 位移层（Transform 的 child）就是整棵页面。外面套重绘边界时，钉住的
    // 顶栏会被反向位移推到边界栅格之外，超出部分直接不画——真机上搜索行
    // 右半截、「分类」按钮、末位标签一起消失，露出黑色画布。
    final translated = find.byType(TabSwipeOffset);
    expect(translated, findsOneWidget);
    var boundary = false;
    tester.element(translated).visitAncestorElements((ancestor) {
      if (ancestor.widget is TabSwipeArea) return false;
      if (ancestor.widget is RepaintBoundary) {
        boundary = true;
        return false;
      }
      return true;
    });
    expect(boundary, isFalse, reason: '位移层被重绘边界包住，顶栏会被栅格裁剪');
  });

  testWidgets('拖动时缺口里铺的是邻页内容', (tester) async {
    await tester.binding.setSurfaceSize(surface);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final index = ValueNotifier<int>(0);
    addTearDown(index.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<int>(
            valueListenable: index,
            builder: (context, value, _) => TabSwipeArea(
              index: value,
              count: 3,
              onSelect: (next) => index.value = next,
              previewBuilder: (target) => ColoredBox(
                color: const Color(0xFF102030),
                child: Center(child: Text('preview $target')),
              ),
              child: Center(child: Text('page $value')),
            ),
          ),
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(TabSwipeArea)),
    );
    await gesture.moveBy(const Offset(-100, 0));
    await tester.pump();

    // 左滑：下一个标签的预览从右侧进来，而不是露一块底色。
    expect(find.text('preview 1'), findsOneWidget);
    expect(find.text('page 0'), findsOneWidget);

    await gesture.moveBy(const Offset(220, 0));
    await tester.pump();
    // 反向拖回第一个标签：左边没有邻页，预览必须撤掉，不能再显示「1」。
    expect(find.textContaining('preview'), findsNothing);
    expect(find.text('page 0'), findsOneWidget);

    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.textContaining('preview'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
