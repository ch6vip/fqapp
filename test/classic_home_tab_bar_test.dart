// 经典首页 tab 条滚动回归：移植自 PiliPlus（Material TabBar isScrollable +
// TabAlignment.center）的「选中即居中滚进视野」与「不足一屏整组居中」。
// 测试字体为 Ahem（每字宽 = 字号），六分类均为两字，几何可精确断言：
// 选中样式 17 → 单标签宽 34 + 2×6 padding = 46。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/app_style_tokens.dart';
import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/widgets/home/classic_home_tab_bar.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 单项宽 46（选中样式 17 × 两字 + 2×6 padding）。
  const itemWidth = 46.0;

  Widget host({
    required int selected,
    required Size size,
    ValueChanged<int>? onSelect,
    bool disableAnimations = false,
  }) {
    return MaterialApp(
      theme: ThemeData(extensions: const [AppStyleTokens.classic()]),
      home: MediaQuery(
        data: MediaQueryData(size: size, disableAnimations: disableAnimations),
        child: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: ClassicHomeTabBar(
              selectedIndex: selected,
              onSelect: onSelect ?? (_) {},
            ),
          ),
        ),
      ),
    );
  }

  ScrollController controllerOf(WidgetTester tester) => tester
      .widget<SingleChildScrollView>(find.byType(SingleChildScrollView))
      .controller!;

  testWidgets('选中屏外标签时自动居中滚进视野', (tester) async {
    // 200 宽 < 自然总宽 348 → 溢出 148，可滚动。
    const size = Size(200, 600);
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(host(selected: 0, size: size));
    await tester.pumpAndSettle();
    final controller = controllerOf(tester);
    expect(controller.offset, 0);
    expect(
      controller.position.maxScrollExtent,
      moreOrLessEquals(148, epsilon: 0.5),
    );

    // 切到第 4 项（index 3）：中心 = 16 + 3×(46+8) + 23 = 201，
    // 居中目标 = 201 − 200/2 = 101，落在 [0,148] 内。
    await tester.pumpWidget(host(selected: 3, size: size));
    await tester.pumpAndSettle();
    expect(controller.offset, moreOrLessEquals(101, epsilon: 0.5));

    // 选中标签真的居中且完整可见。
    final tabRect = tester.getRect(
      find.byKey(const ValueKey('home_category_3')),
    );
    expect(tabRect.center.dx, moreOrLessEquals(100, epsilon: 1));
    expect(tabRect.left, greaterThanOrEqualTo(0));
    expect(tabRect.right, lessThanOrEqualTo(200));
  });

  testWidgets('减弱动态效果下选中即跳变居中，不做滚动动画', (tester) async {
    const size = Size(200, 600);
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      host(selected: 3, size: size, disableAnimations: true),
    );
    // 仅一帧：jumpTo 在帧后同步落位，动画路径此时还停在起点附近。
    await tester.pump();
    final controller = controllerOf(tester);
    expect(controller.offset, moreOrLessEquals(101, epsilon: 0.5));
  });

  testWidgets('eink 同样跳变居中', (tester) async {
    einkModeNotifier.value = true;
    addTearDown(() => einkModeNotifier.value = false);
    const size = Size(200, 600);
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(host(selected: 3, size: size));
    await tester.pump();
    expect(controllerOf(tester).offset, moreOrLessEquals(101, epsilon: 0.5));
  });

  testWidgets('溢出条中已完整可见的标签切换时不额外居中', (tester) async {
    const size = Size(240, 600);
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(host(selected: 0, size: size));
    await tester.pumpAndSettle();
    final controller = controllerOf(tester);
    final target = tester.getRect(
      find.byKey(const ValueKey('home_category_3')),
    );
    expect(target.right, lessThan(size.width));
    await tester.pumpWidget(host(selected: 3, size: size));
    for (var frame = 0; frame < 24; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(controller.offset, 0);
    }
    expect(
      tester.getCenter(find.byKey(const ValueKey('home_tab_indicator'))).dx,
      closeTo(target.center.dx, 0.1),
    );
  });

  testWidgets('标签不足一屏时整组居中且不滚动', (tester) async {
    // 800 宽：间距被撑到上限 8+12=20，自然总宽 408 < 800 → 整组居中。
    const size = Size(800, 600);
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(host(selected: 0, size: size));
    await tester.pumpAndSettle();
    final controller = controllerOf(tester);
    expect(controller.offset, 0);
    expect(controller.position.maxScrollExtent, 0);

    // 首项左 = 16 + (768 − 376)/2 = 212，末项右 = 212 + 376 = 588，
    // 组中心 = 400 = 视口中心。
    final first = tester.getRect(find.byKey(const ValueKey('home_category_0')));
    final last = tester.getRect(find.byKey(const ValueKey('home_category_5')));
    expect(first.left, moreOrLessEquals(212, epsilon: 1));
    expect(last.right, moreOrLessEquals(588, epsilon: 1));
    expect((first.left + last.right) / 2, moreOrLessEquals(400, epsilon: 1));
    // 单项宽仍是预留的 46。
    expect(first.width, moreOrLessEquals(itemWidth, epsilon: 0.5));
  });

  testWidgets('切换标签时下划线在标签中心之间滑动', (tester) async {
    // 800 宽整组居中：标签间距被撑到上限 20，自然总宽 348，rowLeft = 226。
    const size = Size(800, 600);
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(host(selected: 0, size: size));
    await tester.pumpAndSettle();

    // 指示条是树里唯一的 AnimatedPositioned。
    final indicator = find.byKey(const ValueKey('home_tab_indicator'));
    expect(indicator, findsOneWidget);

    // 标签 0 中心在内容坐标 23 → 指示条左 = 196 + 23 − 8 = 211（全局 +16 = 227）。
    final left0 = tester.getRect(indicator).left;

    // 切到标签 1：中心在 46+20+23 = 89 → 指示条左 = 196 + 89 − 8 = 277。
    // 两中心相距 46 + 20 = 66（一项宽 + 间距）。
    await tester.pumpWidget(host(selected: 1, size: size));
    await tester.pumpAndSettle();
    final left1 = tester.getRect(indicator).left;

    expect(
      left1 - left0,
      moreOrLessEquals(66, epsilon: 1),
      reason: '下划线应从标签 0 中心滑到标签 1 中心',
    );
    // 指示条确实可见（非零尺寸）。
    final rect = tester.getRect(indicator);
    expect(rect.width, moreOrLessEquals(16, epsilon: 0.5));
    expect(rect.height, moreOrLessEquals(2.5, epsilon: 0.5));
  });

  testWidgets('eink 下划线直接落位不做滑动动画', (tester) async {
    // eink 下 duration 为 0：切换后一帧内指示条就应到达新中心。
    einkModeNotifier.value = true;
    addTearDown(() => einkModeNotifier.value = false);
    const size = Size(800, 600);
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(host(selected: 0, size: size));
    await tester.pump();
    final left0 = tester
        .getRect(find.byKey(const ValueKey('home_tab_indicator')))
        .left;

    await tester.pumpWidget(host(selected: 2, size: size));
    // 仅一帧：eink 下指示条应立刻跳到标签 2 中心，不等待动画。
    await tester.pump();
    final left2 = tester
        .getRect(find.byKey(const ValueKey('home_tab_indicator')))
        .left;

    // 标签 0 → 标签 2：两中心相距 2×(46+20) = 132。
    expect(left2 - left0, moreOrLessEquals(132, epsilon: 1));
  });

  testWidgets('下划线在动画中途是滑动的，不是一帧跳过去', (tester) async {
    // 这条直接钉住「线没有移动」那个报告：指示条必须在动画中途处于
    // 起点与终点之间，而不是从旧位置瞬间跳到新位置。
    const size = Size(800, 600);
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(host(selected: 0, size: size));
    await tester.pumpAndSettle();
    final indicator = find.byKey(const ValueKey('home_tab_indicator'));
    final start = tester.getRect(indicator).left;

    await tester.pumpWidget(host(selected: 1, size: size));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    final mid = tester.getRect(indicator).left;

    await tester.pumpAndSettle();
    final end = tester.getRect(indicator).left;

    // 中途位置必须严格落在起终点之间。
    expect(mid, greaterThan(start + 1));
    expect(mid, lessThan(end - 1));
    // 终点是标签 1 的中心（标签 0 → 1 相距 46 + 20 = 66）。
    expect(end - start, moreOrLessEquals(66, epsilon: 1));
  });

  testWidgets('下划线动画时长独立于文字动画', (tester) async {
    // 指示条要走一段距离，用文字的 180ms 看起来像跳变；它用 300ms。
    const size = Size(800, 600);
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(host(selected: 0, size: size));
    await tester.pumpAndSettle();

    final widget = tester.widget<AnimatedPositioned>(
      find.byKey(const ValueKey('home_tab_indicator')),
    );
    expect(
      widget.duration,
      const Duration(milliseconds: 300),
      reason: '下划线滑动应比文字动画更长，否则看起来像瞬移',
    );
  });
}
