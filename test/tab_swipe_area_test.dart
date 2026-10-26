import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/widgets/tab_swipe_area.dart';

/// 宿主：标签下标由它自己持有，等同三个页面把自己的状态交给 [TabSwipeArea]。
///
/// [accept] 为假时拒绝一切切换，用来覆盖「父级不认账」那条分支。
/// [overlay] 贴在底部，模拟内容自己带横向拖动的层（短剧卡片的进度条）。
class SwipeHost extends StatefulWidget {
  const SwipeHost({
    super.key,
    required this.requests,
    this.count = 3,
    this.initial = 0,
    this.accept = true,
    this.enabled = true,
    this.overlay,
  });

  final List<int> requests;
  final int count;
  final int initial;
  final bool accept;
  final bool enabled;
  final Widget? overlay;

  @override
  State<SwipeHost> createState() => SwipeHostState();
}

class SwipeHostState extends State<SwipeHost> {
  late int index = widget.initial;

  /// 模拟点标签切过去（不走手势），用来验证入场也对齐同一种观感。
  void goTo(int next) => setState(() => index = next);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: TabSwipeArea(
          index: index,
          count: widget.count,
          enabled: widget.enabled,
          onSelect: (next) {
            widget.requests.add(next);
            if (widget.accept) setState(() => index = next);
          },
          child: Stack(
            children: [
              SizedBox.expand(
                child: Center(
                  key: const Key('swipe-body'),
                  child: Text('tab $index'),
                ),
              ),
              if (widget.overlay != null)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  height: 48,
                  child: widget.overlay!,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 内容当前的横向位移（读的是 [TabSwipeArea] 自己那层 Transform）。
double _offsetX(WidgetTester tester) {
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

Future<void> _pumpHost(
  WidgetTester tester, {
  required List<int> requests,
  int count = 3,
  int initial = 0,
  bool accept = true,
  bool enabled = true,
  Widget? overlay,
  GlobalKey<SwipeHostState>? key,
}) async {
  await tester.binding.setSurfaceSize(const Size(400, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
  await tester.pumpWidget(
    SwipeHost(
      key: key,
      requests: requests,
      count: count,
      initial: initial,
      accept: accept,
      enabled: enabled,
      overlay: overlay,
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  // 400 宽 ⇒ 切换阈值 0.18*400 = 72px，跟手的 1:1 区间 0.28*400 = 112px。
  testWidgets('拖动时内容跟手位移，越过阈值松手切到下一个标签', (tester) async {
    final requests = <int>[];
    await _pumpHost(tester, requests: requests);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('swipe-body'))),
    );
    await gesture.moveBy(const Offset(-60, 0));
    await tester.pump();
    expect(_offsetX(tester), lessThan(-40));

    await gesture.moveBy(const Offset(-140, 0));
    await tester.pump();
    // 越过 112px 的 1:1 区间后按 0.35 收缩：200px 的手势只走约 143px。
    expect(_offsetX(tester), greaterThan(-200));
    expect(_offsetX(tester), lessThan(-140));

    await gesture.up();
    await tester.pumpAndSettle();
    expect(requests, [1]);
    expect(find.text('tab 1'), findsOneWidget);
    expect(_offsetX(tester), 0);
  });

  testWidgets('右滑回到上一个标签', (tester) async {
    final requests = <int>[];
    await _pumpHost(tester, requests: requests, initial: 1);
    await tester.drag(
      find.byKey(const Key('swipe-body')),
      const Offset(200, 0),
    );
    await tester.pumpAndSettle();
    expect(requests, [0]);
    expect(find.text('tab 0'), findsOneWidget);
  });

  testWidgets('位移和速度都不够时弹回原位，不换标签', (tester) async {
    final requests = <int>[];
    await _pumpHost(tester, requests: requests);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('swipe-body'))),
    );
    await gesture.moveBy(const Offset(-40, 0));
    await tester.pump();
    expect(_offsetX(tester), lessThan(0));
    // 停一下再松手：速度采样过期，只剩位移参与判定。
    await tester.pump(const Duration(milliseconds: 300));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(requests, isEmpty);
    expect(find.text('tab 0'), findsOneWidget);
    expect(_offsetX(tester), 0);
  });

  testWidgets('位移不到阈值但甩得够快也换标签', (tester) async {
    final requests = <int>[];
    await _pumpHost(tester, requests: requests);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('swipe-body'))),
    );
    // 累计 -45px（低于 72px 的位移阈值），但 30ms 内完成 ⇒ 约 1500px/s。
    await gesture.moveBy(
      const Offset(-20, 0),
      timeStamp: const Duration(milliseconds: 10),
    );
    await gesture.moveBy(
      const Offset(-15, 0),
      timeStamp: const Duration(milliseconds: 20),
    );
    await gesture.moveBy(
      const Offset(-10, 0),
      timeStamp: const Duration(milliseconds: 30),
    );
    await tester.pump();
    await gesture.up(timeStamp: const Duration(milliseconds: 45));
    await tester.pumpAndSettle();
    expect(requests, [1]);
  });

  testWidgets('首个标签继续右滑只给阻尼位移，不环绕到末位', (tester) async {
    final requests = <int>[];
    await _pumpHost(tester, requests: requests);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('swipe-body'))),
    );
    await gesture.moveBy(const Offset(240, 0));
    await tester.pump();
    // 阻尼 0.3 后再封顶 48px：看得出来在推，但推不动。
    expect(_offsetX(tester), greaterThan(0));
    expect(_offsetX(tester), lessThanOrEqualTo(48));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(requests, isEmpty);
    expect(find.text('tab 0'), findsOneWidget);
    expect(_offsetX(tester), 0);
  });

  testWidgets('末位标签继续左滑同样不环绕', (tester) async {
    final requests = <int>[];
    await _pumpHost(tester, requests: requests, initial: 2);
    await tester.drag(
      find.byKey(const Key('swipe-body')),
      const Offset(-240, 0),
    );
    await tester.pumpAndSettle();
    expect(requests, isEmpty);
    expect(find.text('tab 2'), findsOneWidget);
  });

  testWidgets('enabled 为假时不响应横滑', (tester) async {
    final requests = <int>[];
    await _pumpHost(tester, requests: requests, enabled: false);
    await tester.drag(
      find.byKey(const Key('swipe-body')),
      const Offset(-240, 0),
    );
    await tester.pumpAndSettle();
    expect(requests, isEmpty);
    expect(_offsetX(tester), 0);
  });

  testWidgets('父级拒绝切换时滑回原位，不停在半屏空白上', (tester) async {
    final requests = <int>[];
    await _pumpHost(tester, requests: requests, accept: false);
    await tester.drag(
      find.byKey(const Key('swipe-body')),
      const Offset(-240, 0),
    );
    await tester.pumpAndSettle();
    expect(requests, [1]);
    expect(find.text('tab 0'), findsOneWidget);
    expect(_offsetX(tester), 0);
  });

  testWidgets('点标签切过去时新内容从对应一侧迎进来', (tester) async {
    final requests = <int>[];
    final key = GlobalKey<SwipeHostState>();
    await _pumpHost(tester, requests: requests, key: key);
    key.currentState!.goTo(1);
    await tester.pump();
    // 下一个标签从右侧入场：位移为正，且还没归位。
    expect(_offsetX(tester), greaterThan(50));
    await tester.pumpAndSettle();
    expect(_offsetX(tester), 0);
    expect(find.text('tab 1'), findsOneWidget);
  });

  testWidgets('内层自带横向拖动的条带归它，其余区域整片归外壳', (tester) async {
    final requests = <int>[];
    final innerDeltas = <double>[];
    await _pumpHost(
      tester,
      requests: requests,
      overlay: GestureDetector(
        key: const Key('inner-drag'),
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (details) => innerDeltas.add(details.delta.dx),
        child: const SizedBox.expand(),
      ),
    );

    // 底部那条（相当于短剧卡片上的进度条）自己注册了横向拖动、又比外壳
    // 内层：事件从内层往外发，它先越过 slop、先 accept，所以那一条归它，
    // 外壳不切标签。作用范围靠命中测试分开，不需要按坐标互斥。
    await tester.drag(
      find.byKey(const Key('inner-drag')),
      const Offset(-260, 0),
    );
    await tester.pumpAndSettle();
    expect(innerDeltas, isNotEmpty);
    expect(requests, isEmpty);
    expect(find.text('tab 0'), findsOneWidget);
    expect(_offsetX(tester), 0);

    // 其余区域：整片都能横滑切标签。
    await tester.drag(
      find.byKey(const Key('swipe-body')),
      const Offset(-260, 0),
    );
    await tester.pumpAndSettle();
    expect(requests, [1]);
    expect(find.text('tab 1'), findsOneWidget);
  });

  testWidgets('标签只有一个时手势不启用', (tester) async {
    final requests = <int>[];
    await _pumpHost(tester, requests: requests, count: 1);
    await tester.drag(
      find.byKey(const Key('swipe-body')),
      const Offset(-240, 0),
    );
    await tester.pumpAndSettle();
    expect(requests, isEmpty);
    expect(_offsetX(tester), 0);
  });
}
