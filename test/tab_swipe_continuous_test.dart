import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/widgets/tab_swipe_area.dart';

/// 有邻页预览时的「真页面滚动」换页回归。
///
/// 用户反馈「tag 切换会停顿一下才到下一个界面，没有 PiliPlus 那种连贯」。根因是
/// 旧的 `_commit` 走两段式：先把旧内容**送出** 110ms（这期间新页还没挂上，就是
/// 那一下停顿），再换标签、把新内容从另一侧**迎入** 190ms（换页瞬间预览被丢弃、
/// 真内容跳到入场侧，露出一条底色缺口）。
///
/// 移植 PiliPlus TabBarView 的观感后：有预览就把视口**连续**推到相邻页边界
/// （一屏宽），预览全程可见、铺满整屏的那一刻才换标签并把位移同帧归零——无缝
/// 接管，没有两段之间的停顿，也没有底色缺口。这里逐帧记录「位移 + 标签下标 +
/// 预览是否在树里」，把这三条不变量钉死：
///
/// * 换页前位移**单调**推进到边界，绝不反向退一点（旧版送出/迎入会反向）；
/// * 真的推到了**一屏宽**边界（旧版只到 34% 就换页）；
/// * 标签一旦换成新的，位移**当帧就是 0**（旧版会停在入场侧 +34%）。
class _PageProbe extends StatefulWidget {
  const _PageProbe({
    required this.index,
    required this.mounts,
    required this.disposals,
  });
  final int index;
  final List<int> mounts;
  final List<int> disposals;

  @override
  State<_PageProbe> createState() => _PageProbeState();
}

class _PageProbeState extends State<_PageProbe> {
  @override
  void initState() {
    super.initState();
    widget.mounts.add(widget.index);
  }

  @override
  void dispose() {
    widget.disposals.add(widget.index);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListView.builder(
    key: ValueKey('list-${widget.index}'),
    itemExtent: 60,
    itemCount: 40,
    itemBuilder: (_, row) => Text('page-${widget.index} row-$row'),
  );
}

void main() {
  const surface = Size(400, 800);

  Widget host(ValueNotifier<int> index) => MaterialApp(
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
          child: Center(
            key: const Key('swipe-body'),
            child: Text('page $value'),
          ),
        ),
      ),
    ),
  );

  Future<void> pumpPager(
    WidgetTester tester,
    ValueNotifier<int> index,
    List<int> mounts,
    List<int> disposals, {
    ValueNotifier<double>? progress,
  }) async {
    await tester.binding.setSurfaceSize(surface);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<int>(
          valueListenable: index,
          builder: (context, value, _) => TabSwipeArea.pages(
            index: value,
            count: 4,
            onSelect: (next) => index.value = next,
            onProgress: (value) => progress?.value = value,
            pageBuilder: (context, tab) =>
                _PageProbe(index: tab, mounts: mounts, disposals: disposals),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('真实分页：动画中连续抓手可进入第三页，不等待上一页吸附', (tester) async {
    final index = ValueNotifier(0);
    final progress = ValueNotifier(0.0);
    final mounts = <int>[];
    final disposals = <int>[];
    await pumpPager(tester, index, mounts, disposals, progress: progress);
    final controller = tester
        .widget<PageView>(find.byType(PageView))
        .controller!;
    Future<void> move(TestGesture gesture, double distance) async {
      for (var i = 0; i < 12; i++) {
        await gesture.moveBy(Offset(distance / 12, 0));
        await tester.pump(const Duration(milliseconds: 8));
        expect(
          index.value + progress.value,
          moreOrLessEquals(controller.page!, epsilon: .001),
        );
      }
    }

    var gesture = await tester.startGesture(const Offset(350, 400));
    await move(gesture, -260);
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 16));
    expect(controller.page, inExclusiveRange(.5, 1));
    gesture = await tester.startGesture(const Offset(350, 400));
    // 从上一段截停的位置（约 0.6 页）再走 1.5 页：真正的连续推进能到第三页。
    await move(gesture, -600);
    expect(index.value, 2, reason: '第二次手势不能仍被限制在第一个相邻页');
    await gesture.up();
    await tester.pumpAndSettle();
    expect(controller.page, 2);
    expect(disposals, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    index.dispose();
    progress.dispose();
  });

  testWidgets('真实分页：返回标签复用 State 和滚动位置，隐藏页关闭 ticker', (tester) async {
    final index = ValueNotifier(0);
    final mounts = <int>[];
    final disposals = <int>[];
    await pumpPager(tester, index, mounts, disposals);
    final initial = tester.state(find.byType(_PageProbe));
    await tester.drag(
      find.byKey(const ValueKey('list-0')),
      const Offset(0, -240),
    );
    await tester.pumpAndSettle();
    final scrollable = find.descendant(
      of: find.byKey(const ValueKey('list-0')),
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(scrollable).position;
    final offset = position.pixels;
    for (final target in [1, 2, 3, 0]) {
      index.value = target;
      await tester.pumpAndSettle();
    }
    expect(tester.state(find.byType(_PageProbe)), same(initial));
    expect(tester.state<ScrollableState>(scrollable).position, same(position));
    expect(position.pixels, offset);
    expect(mounts.where((tab) => tab == 0), hasLength(1));
    expect(disposals, isEmpty);
    final hidden = find.byWidgetPredicate(
      (widget) => widget is _PageProbe && widget.index == 1,
      skipOffstage: false,
    );
    expect(TickerMode.valuesOf(tester.element(hidden)).enabled, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(disposals.length, mounts.length);
    index.dispose();
  });

  testWidgets('真实分页：一次长拖跨越多个页面，反向接续也不封顶', (tester) async {
    final index = ValueNotifier(0);
    await pumpPager(tester, index, [], []);
    final gesture = await tester.startGesture(const Offset(350, 400));
    for (var step = 0; step < 24; step++) {
      await gesture.moveBy(const Offset(-40, 0));
      await tester.pump(const Duration(milliseconds: 8));
    }
    expect(index.value, 2);
    for (var step = 0; step < 20; step++) {
      await gesture.moveBy(const Offset(40, 0));
      await tester.pump(const Duration(milliseconds: 8));
    }
    expect(index.value, 0);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    index.dispose();
  });

  double translateX(WidgetTester tester) {
    // 读真内容那层 Transform：预览也在 Stack 里、也带 Transform，按 descendant
    // 取 .first 会误读预览的位移（width+dx），必须锚到内容自己的 key。
    final transform = tester.widget<Transform>(
      find
          .ancestor(
            of: find.byKey(const Key('swipe-body')),
            matching: find.byType(Transform),
          )
          .first,
    );
    return transform.transform.getTranslation().x;
  }

  /// 从内容中心起手，把 [total] 拆成小增量逐帧移动（模拟真实手指，确保横滑
  /// 识别器先越过 slop 赢下竞技场），松手后逐帧记录直到换页归位。
  Future<List<({double dx, int index, bool preview})>> dragAndRecord(
    WidgetTester tester,
    ValueNotifier<int> index,
    Offset total,
  ) async {
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(TabSwipeArea)),
    );
    const steps = 40;
    final step = total / steps.toDouble();
    for (var i = 0; i < steps; i++) {
      await gesture.moveBy(step);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();

    final frames = <({double dx, int index, bool preview})>[];
    for (var frame = 0; frame < 60; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      frames.add((
        dx: translateX(tester),
        index: index.value,
        preview: find.textContaining('preview').evaluate().isNotEmpty,
      ));
      // 换页且归位后再多收几帧，确认稳定停在 0。
      if (index.value != 0 && translateX(tester) == 0 && frame > 20) break;
    }
    return frames;
  }

  testWidgets('长拖松手：视口单调推到一屏宽边界，预览铺满后无缝换页', (tester) async {
    await tester.binding.setSurfaceSize(surface);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final index = ValueNotifier<int>(0);
    addTearDown(index.dispose);
    await tester.pumpWidget(host(index));

    final frames = await dragAndRecord(tester, index, const Offset(-200, 0));

    // 换页前（index 仍是 0）的那一段：位移单调递减，一直推到 -400 边界。
    final outgoing = frames.where((f) => f.index == 0).toList();
    expect(outgoing, isNotEmpty);
    for (var i = 1; i < outgoing.length; i++) {
      expect(
        outgoing[i].dx,
        lessThanOrEqualTo(outgoing[i - 1].dx + 0.5),
        reason: '第 $i 帧位移反向退了（旧版送出/迎入的两段式停顿）',
      );
    }
    expect(
      outgoing.map((f) => f.dx).reduce((a, b) => a < b ? a : b),
      lessThanOrEqualTo(-399),
      reason: '没推到一屏宽边界就换页了（旧版只到 34%）',
    );
    // 推进期间邻页预览一直在树里（缺口里铺的是邻页，不是底色）。
    expect(outgoing.every((f) => f.preview), isTrue);

    // 标签一旦换成 1，位移当帧就是 0：无缝接管，绝不停在入场侧。
    final incoming = frames.where((f) => f.index == 1).toList();
    expect(incoming, isNotEmpty);
    for (final f in incoming) {
      expect(
        f.dx,
        moreOrLessEquals(0, epsilon: 0.5),
        reason: '换页后位移不是 0（旧版停在 +34% 入场侧，露底色缺口）',
      );
      expect(f.preview, isFalse, reason: '换页后预览没撤掉，和真内容同屏了');
    }
    expect(index.value, 1);
    expect(find.text('page 1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('短拖松手：不先反向送出一段，直接连续推进到边界换页', (tester) async {
    await tester.binding.setSurfaceSize(surface);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final index = ValueNotifier<int>(0);
    addTearDown(index.dispose);
    await tester.pumpWidget(host(index));

    // -100px：越过 72px 切换阈值，但不到旧版 136px 的出场距离。旧版会先把
    // 内容从 -100 送到 -136（110ms 的停顿），再换页迎入——正是用户说的「顿一下」。
    final frames = await dragAndRecord(tester, index, const Offset(-100, 0));

    final outgoing = frames.where((f) => f.index == 0).toList();
    expect(outgoing, isNotEmpty);
    for (var i = 1; i < outgoing.length; i++) {
      expect(
        outgoing[i].dx,
        lessThanOrEqualTo(outgoing[i - 1].dx + 0.5),
        reason: '第 $i 帧位移反向（旧版先送出一段的停顿）',
      );
    }
    expect(
      outgoing.map((f) => f.dx).reduce((a, b) => a < b ? a : b),
      lessThanOrEqualTo(-399),
      reason: '短拖也要连续推到一屏宽边界，而不是只到 34% 就换页',
    );
    expect(frames.where((f) => f.index == 1).every((f) => f.dx == 0), isTrue);
    expect(index.value, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('右滑切上一个：同样连续推到 +一屏宽边界再无缝换页', (tester) async {
    await tester.binding.setSurfaceSize(surface);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final index = ValueNotifier<int>(1);
    addTearDown(index.dispose);
    await tester.pumpWidget(host(index));

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(TabSwipeArea)),
    );
    const steps = 40;
    for (var i = 0; i < steps; i++) {
      await gesture.moveBy(const Offset(5, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();

    var sawBoundary = false;
    for (var frame = 0; frame < 60; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      final dx = translateX(tester);
      if (index.value == 1) {
        // 还没换页：位移单调递增推到 +400。
        if (dx >= 399) sawBoundary = true;
      } else {
        // 换页后当帧归零。
        expect(dx, moreOrLessEquals(0, epsilon: 0.5));
      }
    }
    expect(sawBoundary, isTrue, reason: '右滑没连续推到 +一屏宽边界');
    expect(index.value, 0);
    expect(find.text('page 0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
