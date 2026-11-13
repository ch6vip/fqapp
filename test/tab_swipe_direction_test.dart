import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/widgets/tab_swipe_area.dart';

/// 方向判别回归：外壳横滑与内容竖滑在同一个手势竞技场里竞争。
///
/// 复刻首页真实嵌套 `TabSwipeArea > RefreshIndicator > CustomScrollView`：内层
/// 竖滑 `Scrollable` 比外壳横滑更深，指针事件先到它手里，谁先越过 slop 谁赢。
/// 用户反馈「左右滑被当成上下滑」，移植 PiliPlus 的角度守卫（`|dx| > 3·|dy|`
/// 才认横滑、横向 slop 取设备值 +6）后：
///
/// * 干脆的横滑（含轻微纵向抖动）稳稳切标签，内层列表不滚动；
/// * 纵向为主的斜滑归竖滑，不误切标签。
///
/// **为什么用逐帧小步移动而不是一次 `tester.drag`。** 真实手指是一连串小增量，
/// 横滑会在纵向还没越过 slop 时先越过自己的 slop 而赢下竞技场；一次性大位移
/// 会让内层竖滑在同一帧先收到、先接受，测不出真实的方向裁决。
void main() {
  const surface = Size(400, 800);
  const feedKey = Key('direction-feed');

  Widget host(List<int> requests, ScrollController controller, int initial) {
    return MaterialApp(
      home: Scaffold(
        body: _DirectionHost(
          requests: requests,
          controller: controller,
          initial: initial,
        ),
      ),
    );
  }

  Future<void> pumpHost(
    WidgetTester tester, {
    required List<int> requests,
    required ScrollController controller,
    int initial = 0,
  }) async {
    await tester.binding.setSurfaceSize(surface);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(host(requests, controller, initial));
    await tester.pumpAndSettle();
  }

  /// 从列表中心起手，把 [total] 拆成 [steps] 个小增量逐帧移动，模拟真实手指。
  Future<void> incrementalDrag(
    WidgetTester tester,
    Offset total, {
    int steps = 40,
  }) async {
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(feedKey)),
    );
    final step = total / steps.toDouble();
    for (var i = 0; i < steps; i++) {
      await gesture.moveBy(step);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();
  }

  testWidgets('干脆的横滑切标签，内层竖滑列表不滚动', (tester) async {
    final requests = <int>[];
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await pumpHost(tester, requests: requests, controller: controller);

    await incrementalDrag(tester, const Offset(-240, 0));

    expect(requests, [1]);
    expect(controller.offset, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('横滑带轻微纵向抖动（横向远大于纵向）仍切标签', (tester) async {
    final requests = <int>[];
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await pumpHost(tester, requests: requests, controller: controller);

    // 8:1 的斜滑：横向分量远大于纵向，角度守卫放行，横滑先越过 slop 赢下竞技场。
    await incrementalDrag(tester, const Offset(-240, -30));

    expect(requests, [1]);
    expect(controller.offset, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('纯竖滑滚动列表，不切标签', (tester) async {
    final requests = <int>[];
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await pumpHost(tester, requests: requests, controller: controller);

    await incrementalDrag(tester, const Offset(0, -240));

    expect(requests, isEmpty);
    expect(controller.offset, greaterThan(100));
    expect(tester.takeException(), isNull);
  });

  testWidgets('纵向为主的斜滑（横向不足纵向 3 倍）归竖滑，不误切标签', (tester) async {
    final requests = <int>[];
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await pumpHost(tester, requests: requests, controller: controller);

    // 2:1 的斜滑：角度守卫 |dx| > 3|dy| 不成立，横滑永不接受，竖滑赢。
    // 标准横滑识别器只看 |dx|>slop，会在这里抢先切标签——正是用户反馈的误判。
    await incrementalDrag(tester, const Offset(-200, -100));

    expect(requests, isEmpty);
    expect(controller.offset, greaterThan(50));
    expect(tester.takeException(), isNull);
  });
}

/// 持标签下标的宿主，内容是带控制器的竖滑列表（复刻首页 feed）。
class _DirectionHost extends StatefulWidget {
  const _DirectionHost({
    required this.requests,
    required this.controller,
    required this.initial,
  });

  final List<int> requests;
  final ScrollController controller;
  final int initial;

  @override
  State<_DirectionHost> createState() => _DirectionHostState();
}

class _DirectionHostState extends State<_DirectionHost> {
  late int index = widget.initial;

  @override
  Widget build(BuildContext context) {
    return TabSwipeArea(
      index: index,
      count: 3,
      onSelect: (next) {
        widget.requests.add(next);
        setState(() => index = next);
      },
      child: ListView.builder(
        key: const Key('direction-feed'),
        controller: widget.controller,
        itemCount: 40,
        itemBuilder: (context, i) =>
            SizedBox(height: 100, child: Center(child: Text('item $i'))),
      ),
    );
  }
}
