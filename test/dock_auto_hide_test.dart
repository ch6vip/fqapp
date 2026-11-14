// Dock auto-hide regression: user-drag direction drives the hide state
// (PiliPlus parity), horizontal scrolls are ignored, reveal() forces the
// dock back, and reduced-motion users get an instant reposition instead of
// an animation. Notifications are produced by real drags on real scroll
// views (the SDK offers no fake ScrollMetrics to hand-build them).
//
// Additional coverage for the review-driven fixes:
// - P1-1: hidden 时 ExcludeSemantics + IgnorePointer 屏蔽无障碍与命中。
// - P1-2: DockRouteReveal 在子路由 pop 回本页时触发 reveal。
// - P1-3 + P2-5: disabledProbe 短路（桌面滚轮 / 墨水屏）。
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fqapp/widgets/dock_auto_hide.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DockAutoHide hide;

  Future<GlobalKey> pumpShell(
    WidgetTester tester, {
    bool disableAnimations = false,
    bool reduceMotion = false,
    bool Function()? disabledProbe,
  }) async {
    hide = DockAutoHide(disabledProbe: disabledProbe);
    final dockKey = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: disableAnimations),
          child: Scaffold(
            extendBody: true,
            body: NotificationListener<UserScrollNotification>(
              onNotification: (n) {
                hide.handleUserScroll(n);
                return false;
              },
              child: Column(
                children: [
                  // 横向列表放顶部：默认 600 高视口下底部 64px 是
                  // bottomNavigationBar 的地盘，放底部会遮挡拖动。
                  SizedBox(
                    height: 80,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        for (var i = 0; i < 40; i++)
                          SizedBox(width: 120, child: Text('hrow $i')),
                      ],
                    ),
                  ),
                  Expanded(
                    child: ListView(
                      children: [
                        for (var i = 0; i < 40; i++)
                          SizedBox(height: 80, child: Text('row $i')),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            bottomNavigationBar: DockAutoHideSlide(
              hide: hide,
              reduceMotion: reduceMotion,
              child: SizedBox(
                key: dockKey,
                height: 64,
                child: const ColoredBox(color: Colors.blue),
              ),
            ),
          ),
        ),
      ),
    );
    addTearDown(hide.dispose);
    return dockKey;
  }

  AnimatedSlide slideOf(WidgetTester tester, GlobalKey key) => tester
      .widgetList<AnimatedSlide>(
        find.ancestor(
          of: find.byKey(key),
          matching: find.byType(AnimatedSlide),
        ),
      )
      .single;

  ExcludeSemantics excludeOf(WidgetTester tester, GlobalKey key) =>
      tester.widget<ExcludeSemantics>(
        find.byKey(const ValueKey('dock-auto-hide-exclude')),
      );

  IgnorePointer ignoreOf(WidgetTester tester, GlobalKey key) =>
      tester.widget<IgnorePointer>(
        find.byKey(const ValueKey('dock-auto-hide-ignore')),
      );
  testWidgets('dragging the list up hides the dock, dragging down reveals it', (
    tester,
  ) async {
    final dockKey = await pumpShell(tester);
    expect(slideOf(tester, dockKey).offset, const Offset(0, 0));

    // 手指上滑 = 内容下滚（forward 阅读方向）→ 收起，500ms 滑出。
    await tester.drag(find.text('row 5'), const Offset(0, -200));
    await tester.pump();
    expect(hide.hidden, isTrue);
    expect(slideOf(tester, dockKey).offset, const Offset(0, 1));
    // 时长必须真的是 500ms（对齐 PiliPlus 的 AnimatedSlide）：拖完即落定
    // 只能说明目标位是对的，这里是唯一钉住时长的断言。
    expect(
      slideOf(tester, dockKey).duration,
      const Duration(milliseconds: 500),
    );
    await tester.pumpAndSettle();

    // 手指下滑 = 回到上文 → 立即露出。
    await tester.drag(find.text('row 5'), const Offset(0, 200));
    await tester.pump();
    expect(hide.hidden, isFalse);
    expect(slideOf(tester, dockKey).offset, const Offset(0, 0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('horizontal drags never hide the dock', (tester) async {
    final dockKey = await pumpShell(tester);
    await tester.drag(find.text('hrow 5'), const Offset(-200, 0));
    await tester.pump();
    expect(hide.hidden, isFalse);
    expect(slideOf(tester, dockKey).offset, const Offset(0, 0));
    // 横向拖动不应吞掉竖向逻辑之外的任何状态；再验证竖向仍然有效。
    await tester.drag(find.text('row 5'), const Offset(0, -200));
    await tester.pump();
    expect(hide.hidden, isTrue);
  });

  testWidgets('fling momentum keeps the state set by the drag phase', (
    tester,
  ) async {
    final dockKey = await pumpShell(tester);
    // 快速甩动：拖动段收起；惯性段不产生 UserScrollNotification（对齐
    // PiliPlus 只认用户拖动），到顶/到底后状态也不会被 ballistics 翻转。
    await tester.fling(find.text('row 5'), const Offset(0, -600), 2000);
    expect(hide.hidden, isTrue);
    await tester.pumpAndSettle();
    expect(hide.hidden, isTrue);
    expect(slideOf(tester, dockKey).offset, const Offset(0, 1));
  });

  testWidgets('reveal() brings the dock back even without scrolling', (
    tester,
  ) async {
    final dockKey = await pumpShell(tester);
    await tester.drag(find.text('row 5'), const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(hide.hidden, isTrue);
    hide.reveal();
    await tester.pumpAndSettle();
    expect(slideOf(tester, dockKey).offset, const Offset(0, 0));
  });

  testWidgets('reveal() on an already visible dock notifies once at most', (
    tester,
  ) async {
    await pumpShell(tester);
    var notifications = 0;
    hide.addListener(() => notifications++);
    hide.reveal();
    hide.reveal();
    // 已经露出时不产生多余通知（切 tab 频繁调用不重播动画、不重建 dock）。
    expect(notifications, 0);
  });

  testWidgets('reduced motion moves the dock instantly', (tester) async {
    final dockKey = await pumpShell(tester, disableAnimations: true);
    await tester.drag(find.text('row 5'), const Offset(0, -200));
    // 无动画：下一帧就落在收起位，不需要 pumpAndSettle。
    await tester.pump();
    expect(slideOf(tester, dockKey).offset, const Offset(0, 1));
    expect(slideOf(tester, dockKey).duration, Duration.zero);
  });

  // 墨水屏的 reduceMotion 现在只是「动画层」的兜底：真正的完全禁用由
  // disabledProbe 短路（见下面的用例）。保留这条断言是为了防止有人把
  // Duration.zero 判断写错时漏红。
  testWidgets('e-ink reduceMotion lands the dock without sliding', (
    tester,
  ) async {
    final dockKey = await pumpShell(tester, reduceMotion: true);
    await tester.drag(find.text('row 5'), const Offset(0, -200));
    await tester.pump();
    expect(hide.hidden, isTrue);
    expect(slideOf(tester, dockKey).offset, const Offset(0, 1));
    expect(slideOf(tester, dockKey).duration, Duration.zero);
  });

  // P1-3 + P2-5：桌面滚轮与墨水屏经 disabledProbe 完全短路，hidden
  // 保持 false，dock 常驻可见。探针翻回 false 后，同一实例仍会
  // 正常响应（验证不是一次性开关）。
  testWidgets('disabledProbe short-circuits user drags (desktop / e-ink)', (
    tester,
  ) async {
    var disabled = true;
    final dockKey = await pumpShell(tester, disabledProbe: () => disabled);
    await tester.drag(find.text('row 5'), const Offset(0, -200));
    await tester.pump();
    expect(hide.hidden, isFalse, reason: '探针开启时拖动不应翻转 hidden');
    expect(slideOf(tester, dockKey).offset, const Offset(0, 0));

    // 探针翻回 false：同一个控制器仍然可用。
    disabled = false;
    await tester.drag(find.text('row 5'), const Offset(0, -200));
    await tester.pump();
    expect(hide.hidden, isTrue, reason: '探针关闭后拖动应恢复默认行为');
  });

  // 安全网：dock 已收起后进入 disabled 模式（模拟切换墨水屏），
  // 反向拖动被短路无法自主 reveal，必须由外部调用 reveal() 恢复。
  testWidgets('entering disabled mode while hidden requires external reveal', (
    tester,
  ) async {
    var disabled = false;
    await pumpShell(tester, disabledProbe: () => disabled);
    // 先收起。
    await tester.drag(find.text('row 5'), const Offset(0, -200));
    await tester.pump();
    expect(hide.hidden, isTrue);

    // 探针开启（模拟进入 eink）。
    disabled = true;
    // 反向拖动被 disabledProbe 短路，无法自主恢复。
    await tester.drag(find.text('row 5'), const Offset(0, 200));
    await tester.pump();
    expect(hide.hidden, isTrue, reason: 'disabledProbe 应阻止反向 reveal');

    // 只有外部 reveal（模拟 _onEinkModeChanged）才能把 dock 带回来。
    hide.reveal();
    await tester.pump();
    expect(hide.hidden, isFalse);
  });

  // eink 下的 reveal 必须零帧落位：P1 场景里 RootShell 需同时 setState
  // 把新的 reduceMotion 刷到 DockAutoHideSlide，否则 reveal 过渡仍会跑
  // 500ms 平移。本用例在 widget 层钉住该契约：reduceMotion=true 时，
  // hidden 由 true→false 的 reveal 同样适用 Duration.zero。
  testWidgets('e-ink reveal transition uses zero duration', (tester) async {
    final dockKey = await pumpShell(tester, reduceMotion: true);
    // 先滑到收起位（reduceMotion=true 下本身就是零帧）。
    await tester.drag(find.text('row 5'), const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(hide.hidden, isTrue);
    // 外部 reveal 把 hidden 翻回 false，widget 仍应给 Duration.zero。
    hide.reveal();
    await tester.pump();
    expect(hide.hidden, isFalse);
    expect(
      slideOf(tester, dockKey).duration,
      Duration.zero,
      reason: 'eink 下的 reveal 必须零帧落位',
    );
  });

  // P1-1：hidden 时 ExcludeSemantics + IgnorePointer 必须同时开启，避免
  // TalkBack/VoiceOver 读到不可见按钮，或指针意外命中屏幕外区域。
  testWidgets('hidden state excludes dock from semantics and hit test', (
    tester,
  ) async {
    final dockKey = await pumpShell(tester);
    // 露出态：无障碍 & 命中都开启（不排除、不忽略）。
    expect(excludeOf(tester, dockKey).excluding, isFalse);
    expect(ignoreOf(tester, dockKey).ignoring, isFalse);
    // 拖动收起：两者同时翻转。
    await tester.drag(find.text('row 5'), const Offset(0, -200));
    await tester.pump();
    expect(hide.hidden, isTrue);
    expect(excludeOf(tester, dockKey).excluding, isTrue);
    expect(ignoreOf(tester, dockKey).ignoring, isTrue);
    // reveal 后回归可用。
    hide.reveal();
    await tester.pump();
    expect(excludeOf(tester, dockKey).excluding, isFalse);
    expect(ignoreOf(tester, dockKey).ignoring, isFalse);
  });

  // P1-2 单独一组：需要一个真实 Navigator，push 一个覆盖路由再 pop 回来，
  // secondaryAnimation 才会真的跑起来。
  group('DockRouteReveal', () {
    testWidgets('reveals the dock when a covering route pops back', (
      tester,
    ) async {
      final hide = DockAutoHide();
      addTearDown(hide.dispose);
      BuildContext? shellContext;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              shellContext = context;
              return const Scaffold(body: Center(child: Text('shell')));
            },
          ),
        ),
      );
      final reveal = DockRouteReveal(hide);
      // RootShell 的 didChangeDependencies 语义：手动 attach 一次。
      reveal.attach(shellContext!);

      // 收起 → 子路由 push → 盖住 → pop 回来 → 应自动 reveal。
      hide.reveal();
      hide.value = true;
      expect(hide.hidden, isTrue);

      Navigator.of(shellContext!).push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('top')),
        ),
      );
      await tester.pumpAndSettle();
      // push 完成后 secondaryAnimation 会走到 1，_covered=true。
      hide.value = true;
      expect(hide.hidden, isTrue);

      Navigator.of(shellContext!).pop();
      await tester.pumpAndSettle();
      // pop 结束，secondaryAnimation 回到 0，_covered 从 true→false，
      // 触发 reveal 一次。
      expect(hide.hidden, isFalse);

      reveal.detach();
    });

    testWidgets('no reveal fires while still covered', (tester) async {
      final hide = DockAutoHide();
      addTearDown(hide.dispose);
      BuildContext? shellContext;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              shellContext = context;
              return const Scaffold(body: Center(child: Text('shell')));
            },
          ),
        ),
      );
      final reveal = DockRouteReveal(hide);
      reveal.attach(shellContext!);
      Navigator.of(shellContext!).push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('top')),
        ),
      );
      await tester.pumpAndSettle();
      hide.value = true;
      // 上层还有路由时，secondaryAnimation 停在 1，_onChange 不应触发 reveal。
      expect(hide.hidden, isTrue);
      reveal.detach();
    });
  });
}
