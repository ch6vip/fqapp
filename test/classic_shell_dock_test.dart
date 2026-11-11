// Classic dock regression: concentric geometry (outer capsule vs selection
// backdrop), full icon+label coverage, and the draggable highlight that
// follows the finger and switches pages on release.
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart'
    show SemanticsAction, SemanticsActionEvent;
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/app_style_tokens.dart';
import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/widgets/classic_shell_dock.dart';
import 'package:fqapp/widgets/home/home_design.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // dock 外轮廓：64 高全胶囊（圆角 32）；选中背景内缩 4、圆角 28 = 32 − 4。
  const outerRadius = 32.0;
  const inset = 4.0;
  const innerRadius = outerRadius - inset;

  // 400 宽屏幕：dock 内容区宽 368 − 8 = 360，均分 4 项 = 90。
  const itemWidth = 90.0;
  // 项 i 的背景块 left = 16(页边) + 4(内缩) + i × 90。
  double selectionLeft(int index) => 20 + index * itemWidth;

  Future<void> pumpDock(
    WidgetTester tester, {
    required int selectedIndex,
    Brightness brightness = Brightness.light,
    bool eink = false,
    ValueChanged<int>? onSelected,
    Size size = const Size(400, 900),
    bool settle = true,
    bool disableAnimations = false,
  }) async {
    einkModeNotifier.value = eink;
    addTearDown(() => einkModeNotifier.value = false);
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          brightness: brightness,
          extensions: const [AppStyleTokens.classic()],
        ),
        home: MediaQuery(
          data: MediaQueryData(size: size, disableAnimations: disableAnimations),
          child: Scaffold(
            body: const SizedBox.expand(),
            bottomNavigationBar: ClassicShellDock(
              selectedIndex: selectedIndex,
              onSelected: onSelected ?? (_) {},
              overVideo: false,
            ),
          ),
        ),
      ),
    );
    if (settle) {
      await tester.pumpAndSettle();
    }
  }

  /// 交互用例公共泵：持有可变选中态，切换结果通过 [onSelected] 回传给用例。
  Future<void> pumpInteractiveDock(
    WidgetTester tester, {
    required int initial,
    required ValueChanged<int> onSelected,
    bool disableAnimations = false,
  }) async {
    var selected = initial;
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) {
          return MaterialApp(
            theme: ThemeData(extensions: const [AppStyleTokens.classic()]),
            home: MediaQuery(
              data: MediaQueryData(
                size: const Size(400, 900),
                disableAnimations: disableAnimations,
              ),
              child: Scaffold(
                body: const SizedBox.expand(),
                bottomNavigationBar: ClassicShellDock(
                  selectedIndex: selected,
                  onSelected: (index) {
                    selected = index;
                    onSelected(index);
                    setState(() {});
                  },
                  overVideo: false,
                ),
              ),
            ),
          );
        },
      ),
    );
    await tester.pumpAndSettle();
  }

  BoxDecoration selectionDecoration(WidgetTester tester) =>
      tester
              .widget<DecoratedBox>(
                find.byKey(const ValueKey('classic-dock-selection')),
              )
              .decoration
          as BoxDecoration;

  BoxDecoration surfaceDecoration(WidgetTester tester) =>
      tester
              .widget<Container>(
                find.byKey(const ValueKey('classic-dock-surface')),
              )
              .decoration!
          as BoxDecoration;

  double radiusOf(BoxDecoration decoration) =>
      decoration.borderRadius!.resolve(TextDirection.ltr).topLeft.x;

  Rect selectionRect(WidgetTester tester) =>
      tester.getRect(find.byKey(const ValueKey('classic-dock-selection')));

  testWidgets('outer capsule nests the selection backdrop concentrically', (
    tester,
  ) async {
    await pumpDock(tester, selectedIndex: 0);

    final dockRect = tester.getRect(
      find.byKey(const ValueKey('classic-dock-surface')),
    );
    final bgRect = selectionRect(tester);

    // 外轮廓 64 高、圆角 32 = 高/2 的全胶囊。
    expect(dockRect.height, 64);
    expect(radiusOf(surfaceDecoration(tester)), outerRadius);

    // 贴边侧（左侧、上下）内缩均匀 4px；右侧是相邻项边界不贴边。
    expect(bgRect.left - dockRect.left, moreOrLessEquals(inset, epsilon: 0.01));
    expect(dockRect.right - bgRect.right, greaterThan(inset));
    expect(bgRect.top - dockRect.top, moreOrLessEquals(inset, epsilon: 0.01));
    expect(
      dockRect.bottom - bgRect.bottom,
      moreOrLessEquals(inset, epsilon: 0.01),
    );

    // 尾项贴边侧（右侧）同样内缩 4px。
    await pumpDock(tester, selectedIndex: 3);
    final lastRect = selectionRect(tester);
    expect(
      dockRect.right - lastRect.right,
      moreOrLessEquals(inset, epsilon: 0.01),
    );
    expect(lastRect.left - dockRect.left, greaterThan(inset));

    // 同心规则：内层圆角 = 外层圆角 − 内缩间距。
    expect(radiusOf(selectionDecoration(tester)), innerRadius);

    // 背景不溢出 dock。
    expect(dockRect.contains(bgRect.topLeft), isTrue);
    expect(dockRect.contains(bgRect.bottomRight), isTrue);
  });

  testWidgets('selection backdrop wraps the icon and the label', (
    tester,
  ) async {
    await pumpDock(tester, selectedIndex: 2);

    final bgRect = selectionRect(tester);
    final iconRect = tester.getRect(find.byIcon(LucideIcons.library_big));
    final labelRect = tester.getRect(find.text('书架'));

    // 图标与文字完整落在背景内。
    expect(bgRect.contains(iconRect.topLeft), isTrue);
    expect(bgRect.contains(iconRect.bottomRight), isTrue);
    expect(bgRect.contains(labelRect.topLeft), isTrue);
    expect(bgRect.contains(labelRect.bottomRight), isTrue);

    // 上下留白对称且不贴边（内容块居中、四周有余量）。
    final topGap = iconRect.top - bgRect.top;
    final bottomGap = bgRect.bottom - labelRect.bottom;
    expect(topGap, greaterThan(inset));
    expect(bottomGap, greaterThan(inset));
    expect(topGap, moreOrLessEquals(bottomGap, epsilon: 1.5));
  });

  testWidgets('tapping a destination slides the highlight over', (
    tester,
  ) async {
    var selected = 2;
    await pumpInteractiveDock(
      tester,
      initial: 2,
      onSelected: (i) => selected = i,
    );

    await tester.tap(find.text('首页'));
    expect(selected, 0);
    // tap 那一帧背景开始弹簧滑动（与页面 PageView 的滑动过渡并行），
    // 不再瞬时落位：一帧后已离开起点、仍在途中。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    final traveling = selectionRect(tester).left;
    expect(traveling, lessThan(selectionLeft(2) - 20));
    expect(traveling, greaterThan(selectionLeft(0) + 10));
    await tester.pumpAndSettle();

    expect(selected, 0);
    // 背景块稳定在项 0（颜色恒为高亮色，不再有每项独立的淡入淡出）。
    expect(
      selectionRect(tester).left,
      moreOrLessEquals(selectionLeft(0), epsilon: 1),
    );
    expect(
      selectionDecoration(tester).color,
      HomePalette.accent.withValues(alpha: .12),
    );
  });

  testWidgets('page-side selection changes slide the highlight too', (
    tester,
  ) async {
    // 页面侧切换（书架空态「去书城找书」、系统返回等）：selectedIndex
    // 直接变化，不在 dock 上点击——背景同样弹簧滑向新项，与 PageView
    // 的滑动过渡并行，不再瞬时落位。
    await pumpDock(tester, selectedIndex: 2);
    await pumpDock(tester, selectedIndex: 0, settle: false);

    await tester.pump(const Duration(milliseconds: 60));
    final traveling = selectionRect(tester).left;
    expect(traveling, lessThan(selectionLeft(2) - 20));
    expect(traveling, greaterThan(selectionLeft(0) + 10));
    await tester.pumpAndSettle();
    expect(
      selectionRect(tester).left,
      moreOrLessEquals(selectionLeft(0), epsilon: 1),
    );
  });

  testWidgets('spring converges over ~290ms, not within the first frames', (
    tester,
  ) async {
    // 回归：Ticker 回调传入的是累计时长而非帧间隔，若直接当 dt 用，
    // 逼近系数会逐帧增大、约 100ms 就收敛（与 260ms 页面滑动失步）。
    // 正确实现按帧差分 dt，多帧后（~112ms）高亮应仍在途中。
    var selected = 2;
    await pumpInteractiveDock(
      tester,
      initial: 2,
      onSelected: (i) => selected = i,
    );
    await tester.tap(find.text('首页'));
    await tester.pump(); // 启动弹簧
    for (var i = 0; i < 7; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final traveling = selectionRect(tester).left;
    // 7 帧后仍未落位（若误用累计时间作 dt，此处已几乎到达项 0）。
    expect(traveling, greaterThan(selectionLeft(0) + 8));
    expect(traveling, lessThan(selectionLeft(2) - 20));
    await tester.pumpAndSettle();
    expect(selected, 0);
    expect(
      selectionRect(tester).left,
      moreOrLessEquals(selectionLeft(0), epsilon: 1),
    );
  });

  testWidgets('rapid successive switches restart the spring without error', (
    tester,
  ) async {
    // 回归：弹簧未收敛时再次切 tab，didUpdateWidget 会再次 _settleTo。
    // Ticker.start() 不允许作用于活跃 Ticker（debug 下抛 "started twice"），
    // 必须先 stop 再 start。
    var selected = 0;
    await pumpInteractiveDock(
      tester,
      initial: 0,
      onSelected: (i) => selected = i,
    );
    await tester.tap(find.text('书架')); // -> 2，启动弹簧
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60)); // 仍在途中
    await tester.tap(find.text('我的')); // -> 3，弹簧活跃时再次 _settleTo
    await tester.pump(); // 若重复 start 活跃 Ticker，此处抛异常
    await tester.pumpAndSettle();
    expect(selected, 3);
    expect(
      selectionRect(tester).left,
      moreOrLessEquals(selectionLeft(3), epsilon: 1),
    );
  });

  testWidgets('system reduce-motion snaps the highlight without travel', (
    tester,
  ) async {
    // 无障碍：系统「减弱动态效果」开启时高亮直接落位、不做弹簧
    // 滑动（与全库动画按 disableAnimations 降级的约定一致）。
    var selected = 2;
    await pumpInteractiveDock(
      tester,
      initial: 2,
      onSelected: (i) => selected = i,
      disableAnimations: true,
    );
    await tester.tap(find.text('首页'));
    await tester.pump();
    expect(selected, 0);
    // 无动画分支：一帧内已在项 0，不存在途中位置。
    expect(
      selectionRect(tester).left,
      moreOrLessEquals(selectionLeft(0), epsilon: 1),
    );
  });

  testWidgets('dragging the dock tracks the finger and switches on release', (
    tester,
  ) async {
    var selected = 2;
    await pumpInteractiveDock(
      tester,
      initial: 2,
      onSelected: (i) => selected = i,
    );

    // 从“书架”（项 2）实际中心起拖，左移 60px（> 半程 45）。
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('书架')),
    );
    await gesture.moveBy(const Offset(-60, 0));
    await tester.pump();

    // 未松手：背景块精确跟手（中心 245 − 60 = 185），页面未切换。
    final tracking = selectionRect(tester);
    expect(tracking.left, moreOrLessEquals(140, epsilon: 1));
    expect(selected, 2);

    // 松手：跨过半程 → 切到项 1，背景块滑到位。
    await gesture.up();
    await tester.pumpAndSettle();
    expect(selected, 1);
    expect(
      selectionRect(tester).left,
      moreOrLessEquals(selectionLeft(1), epsilon: 1),
    );
  });

  testWidgets('short drag springs back without switching', (tester) async {
    var selected = 2;
    await pumpInteractiveDock(
      tester,
      initial: 2,
      onSelected: (i) => selected = i,
    );

    // 慢速小位移（< 半程 45、速度 < 600）：松手回弹，不切换。
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('书架')),
    );
    await gesture.moveBy(const Offset(-15, 0));
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.moveBy(const Offset(-15, 0));
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(selected, 2);
    expect(
      selectionRect(tester).left,
      moreOrLessEquals(selectionLeft(2), epsilon: 1),
    );
  });

  testWidgets('drag release rebounds past the resting position then settles', (
    tester,
  ) async {
    // 回弹手感：松手后不是单调滑回（旧指数逼近无过冲、观感过于
    // 简单），而是欠阻尼弹簧先冲过静止位再振荡归位。ζ=0.5 时
    // 过冲峰值 ≈ 静止位右侧 5px（峰值在松手后 ≈165ms 处）。
    var selected = 2;
    await pumpInteractiveDock(
      tester,
      initial: 2,
      onSelected: (i) => selected = i,
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('书架')),
    );
    await gesture.moveBy(const Offset(-30, 0));
    await tester.pump();
    expect(
      selectionRect(tester).left,
      moreOrLessEquals(selectionLeft(2) - 30, epsilon: 1),
    );
    await gesture.up();
    await tester.pump();
    // 启动帧仍在拖放侧（静止位左边）。
    expect(selectionRect(tester).left, lessThan(selectionLeft(2)));
    // 扫描 ~320ms 窗口：必然越过静止位（若回弹无过冲，最大值
    // 只会无限接近静止位而不会超过它）。
    var maxLeft = selectionRect(tester).left;
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      final left = selectionRect(tester).left;
      if (left > maxLeft) maxLeft = left;
    }
    expect(maxLeft, greaterThan(selectionLeft(2) + 2));
    await tester.pumpAndSettle();
    expect(selected, 2);
    expect(
      selectionRect(tester).left,
      moreOrLessEquals(selectionLeft(2), epsilon: 1),
    );
  });

  testWidgets('dragging across several tabs lands on the far tab', (
    tester,
  ) async {
    var selected = 2;
    await pumpInteractiveDock(
      tester,
      initial: 2,
      onSelected: (i) => selected = i,
    );

    // 从“书架”直接拖向“首页”（跨 2 项）：背景块 clamp 在内容区左端，
    // 松手按连续位置取整直接落到项 0，页面切换跳过中间项。
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('书架')),
    );
    await gesture.moveBy(const Offset(-200, 0));
    await tester.pump();
    expect(
      selectionRect(tester).left,
      moreOrLessEquals(selectionLeft(0), epsilon: 1),
    );
    expect(selected, 2);

    await gesture.up();
    // 切页的那一帧：拖满整数位置时归位动画瞬时结束，页面侧切换不得
    // 把背景闪回旧项再重滑（曾闪回项 2、滑到项 1 附近又跳回项 0）。
    await tester.pump();
    expect(selected, 0);
    expect(
      selectionRect(tester).left,
      moreOrLessEquals(selectionLeft(0), epsilon: 1),
    );
    await tester.pumpAndSettle();
    expect(selected, 0);
    expect(
      selectionRect(tester).left,
      moreOrLessEquals(selectionLeft(0), epsilon: 1),
    );
  });

  testWidgets('a fling advances one tab without passing halfway', (
    tester,
  ) async {
    var selected = 2;
    await pumpInteractiveDock(
      tester,
      initial: 2,
      onSelected: (i) => selected = i,
    );

    // 位移仅 40px（< 半程 45）但甩动速度快：沿甩动方向至少前进一格。
    // widget 测试的事件默认时间戳全为 0，VelocityTracker 拟合不出速度；
    // 显式传递增时间戳才能产生真实甩动速度。
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('书架')),
    );
    await gesture.moveBy(
      const Offset(-20, 0),
      timeStamp: const Duration(milliseconds: 16),
    );
    await gesture.moveBy(
      const Offset(-20, 0),
      timeStamp: const Duration(milliseconds: 32),
    );
    await gesture.up(timeStamp: const Duration(milliseconds: 32));
    await tester.pumpAndSettle();
    expect(selected, 1);
    expect(
      selectionRect(tester).left,
      moreOrLessEquals(selectionLeft(1), epsilon: 1),
    );
  });

  testWidgets('dock caps its width and centers on wide screens', (
    tester,
  ) async {
    // 平板宽屏：旧实现用 Expanded 均分整行，dock 被拉伸到 768 宽；
    // 现在封顶 368 并水平居中，单项宽度与手机一致。
    await pumpDock(tester, selectedIndex: 0, size: const Size(800, 900));

    final dockRect = tester.getRect(
      find.byKey(const ValueKey('classic-dock-surface')),
    );
    expect(dockRect.width, moreOrLessEquals(368, epsilon: 0.01));
    expect(dockRect.center.dx, moreOrLessEquals(400, epsilon: 0.01));

    // 单项宽度保持手机的 90（背景块宽 = 均分项宽），同心内缩不变。
    final bgRect = selectionRect(tester);
    expect(bgRect.width, moreOrLessEquals(itemWidth, epsilon: 0.01));
    expect(bgRect.left - dockRect.left, moreOrLessEquals(inset, epsilon: 0.01));
    expect(
      bgRect.center.dx,
      moreOrLessEquals(tester.getRect(find.text('首页')).center.dx, epsilon: 1),
    );
  });

  testWidgets('eink keeps the same geometry with white-on-black selection', (
    tester,
  ) async {
    await pumpDock(tester, selectedIndex: 0, eink: true);

    final bgRect = selectionRect(tester);
    final dockRect = tester.getRect(
      find.byKey(const ValueKey('classic-dock-surface')),
    );
    // 同心几何在 eink 下不变。
    expect(bgRect.height, 64 - 2 * inset);
    expect(bgRect.top - dockRect.top, inset);
    expect(radiusOf(selectionDecoration(tester)), innerRadius);

    // 黑底上的图标与文字一起反白。
    expect(selectionDecoration(tester).color, Colors.black);
    expect(
      tester.widget<Icon>(find.byIcon(LucideIcons.house)).color,
      Colors.white,
    );
    expect(tester.widget<Text>(find.text('首页')).style!.color, Colors.white);
  });

  testWidgets('dark glass surface uses the stronger accent tint', (
    tester,
  ) async {
    await pumpDock(tester, selectedIndex: 1, brightness: Brightness.dark);

    expect(
      selectionDecoration(tester).color,
      HomePalette.accent.withValues(alpha: .20),
    );
    // 深色玻璃下选中文字用 accent。
    expect(
      tester.widget<Text>(find.text('短剧')).style!.color,
      HomePalette.accent,
    );
  });

  testWidgets('入口 Semantics 注册 tap 激活动作，屏幕阅读器双击可切换', (
    tester,
  ) async {
    // PR #320 审查遗留：手势在子级 GestureDetector 上，外层 Semantics 只标
    // button/selected 时 TalkBack 能读出但双击无法激活，须显式补 onTap。
    final handle = tester.ensureSemantics();
    try {
      var selected = -1;
      await pumpInteractiveDock(
        tester,
        initial: 0,
        onSelected: (index) => selected = index,
      );

      const labels = ['首页', '短剧', '书架', '我的'];
      for (final label in labels) {
        // widget 级：入口的 Semantics 必须显式持有 onTap。
        final semantics = tester.widget<Semantics>(
          find
              .ancestor(of: find.text(label), matching: find.byType(Semantics))
              .first,
        );
        expect(
          semantics.properties.onTap,
          isNotNull,
          reason: '$label 缺少语义激活动作',
        );
        // 节点级：合并后的语义节点带 tap 动作。
        final node = tester.getSemantics(find.bySemanticsLabel(label));
        expect(
          node.getSemanticsData().hasAction(SemanticsAction.tap),
          isTrue,
          reason: label,
        );
      }

      // 模拟屏幕阅读器双击：执行语义 tap 动作应真的切换选中项。
      final shelfNode = tester.getSemantics(find.bySemanticsLabel('书架'));
      tester.binding.performSemanticsAction(
        SemanticsActionEvent(
          type: SemanticsAction.tap,
          viewId: tester.view.viewId,
          nodeId: shelfNode.id,
        ),
      );
      await tester.pumpAndSettle();
      expect(selected, 2);
    } finally {
      handle.dispose();
    }
  });
}
