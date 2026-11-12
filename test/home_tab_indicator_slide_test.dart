import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/app_style_tokens.dart';
import 'package:fqapp/widgets/home/classic_home_tab_bar.dart';
import 'package:fqapp/widgets/tab_swipe_area.dart';

/// A host that behaves like the real page: the tab bar sits outside the swipe
/// area and the selection really moves when the swipe area asks for it.
class _Host extends StatefulWidget {
  const _Host({this.initial = 0, this.preview = false});

  final int initial;
  final bool preview;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late int _index = widget.initial;
  final ValueNotifier<double> _progress = ValueNotifier<double>(0);
  final List<double> _seen = <double>[];

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        ValueListenableBuilder<double>(
          valueListenable: _progress,
          builder: (context, value, _) => ClassicHomeTabBar(
            selectedIndex: _index,
            onSelect: (index) => setState(() => _index = index),
            progress: value,
          ),
        ),
        Expanded(
          child: TabSwipeArea(
            index: _index,
            count: 4,
            onSelect: (index) => setState(() => _index = index),
            onProgress: (value) {
              _seen.add(value);
              _progress.value = value;
            },
            previewBuilder: widget.preview
                ? (_) => const SizedBox.expand()
                : null,
            child: const SizedBox.expand(),
          ),
        ),
      ],
    ),
  );
}

void main() {
  const indicatorKey = ValueKey('home_tab_indicator');
  const blockKey = ValueKey('home_tab_selection_block');

  Future<void> pumpHost(
    WidgetTester tester, {
    int initial = 0,
    bool preview = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: _Host(initial: initial, preview: preview),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final initial in [0, 2]) {
    for (final mode in ['点按', '滑动', '预览滑动']) {
      testWidgets('$mode 从 $initial 到 1：逐帧不得越过目标或反向回弹', (tester) async {
        await tester.binding.setSurfaceSize(const Size(360, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await pumpHost(tester, initial: initial, preview: mode == '预览滑动');
        final state = tester.state<_HostState>(find.byType(_Host));
        final direction = initial == 0 ? 1 : -1;
        final target = tester
            .getCenter(find.byKey(const ValueKey('home_category_1')))
            .dx;
        var previous = tester.getCenter(find.byKey(indicatorKey)).dx;

        if (mode == '点按') {
          await tester.tap(find.byKey(const ValueKey('home_category_1')));
        } else {
          final gesture = await tester.startGesture(const Offset(180, 500));
          for (var i = 0; i < 10; i++) {
            await gesture.moveBy(Offset(-10.0 * direction, 0));
            await tester.pump(const Duration(milliseconds: 16));
          }
          previous = tester.getCenter(find.byKey(indicatorKey)).dx;
          await gesture.up();
        }
        // 包含提交帧；只等动画结束会遗漏瞬间跳到再下一标签的问题。
        await tester.pump();
        for (var frame = 0; frame < 45; frame++) {
          final centre = tester.getCenter(find.byKey(indicatorKey)).dx;
          expect(
            (centre - target) * direction,
            lessThanOrEqualTo(0.1),
            reason: '第 $frame 帧越过目标：$centre，目标 $target',
          );
          expect(
            (centre - previous) * direction,
            greaterThanOrEqualTo(-0.1),
            reason: '第 $frame 帧反向回弹：$previous → $centre',
          );
          previous = centre;
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(state._index, 1);
        expect(state._progress.value, 0);
        expect(previous, closeTo(target, 0.1));
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('拖动中指示条跟着手指走', (tester) async {
    await pumpHost(tester);

    final before = tester.getRect(find.byKey(indicatorKey)).left;

    // Drag left: that is halfway to the next tab.
    await tester.dragFrom(const Offset(400, 500), const Offset(-200, 0));
    await tester.pump();

    // The indicator animates to the new spot, so give it a few frames.
    await tester.pump(const Duration(milliseconds: 400));

    final after = tester.getRect(find.byKey(indicatorKey)).left;
    expect(
      after,
      isNot(moreOrLessEquals(before, epsilon: 0.5)),
      reason: '拖动时下划线必须离开原位',
    );
  });

  testWidgets('拖过阈值换页后，下划线落在新标签上', (tester) async {
    await pumpHost(tester);

    final before = tester.getRect(find.byKey(indicatorKey)).left;

    // Past the commit threshold (18% of the width), so the page really swaps.
    await tester.dragFrom(const Offset(600, 500), const Offset(-400, 0));
    await tester.pumpAndSettle();

    final tab1 = tester.getRect(find.byKey(const ValueKey('home_category_1')));
    final after = tester.getRect(find.byKey(indicatorKey)).left;

    expect(
      after,
      isNot(moreOrLessEquals(before, epsilon: 0.5)),
      reason: '换页后下划线必须换到新标签',
    );
    expect(
      after + 8,
      moreOrLessEquals(tab1.center.dx, epsilon: 2),
      reason: '换页后下划线要落在新标签的中心',
    );
  });

  testWidgets('取消拖动后进度和下划线一起归位', (tester) async {
    await pumpHost(tester);
    final state = tester.state<_HostState>(find.byType(_Host));
    final start = tester.getCenter(find.byKey(indicatorKey)).dx;
    final gesture = await tester.startGesture(const Offset(400, 500));
    await gesture.moveBy(const Offset(-100, 0));
    await tester.pump();
    expect(state._progress.value, greaterThan(0));
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(state._progress.value, 0);
    expect(state._index, 0);
    expect(tester.getCenter(find.byKey(indicatorKey)).dx, closeTo(start, 0.1));
  });

  testWidgets('进度在两个标签中心之间插值', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: const [AppStyleTokens.classic()]),
        home: const Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: ClassicHomeTabBar(
              selectedIndex: 0,
              onSelect: _noop,
              progress: 0.5,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final tab0 = tester.getRect(find.byKey(const ValueKey('home_category_0')));
    final tab1 = tester.getRect(find.byKey(const ValueKey('home_category_1')));
    final indicator = tester.getRect(find.byKey(indicatorKey));

    // 指示条中心落在两个标签中心之间。
    final indicatorCentre = indicator.center.dx;
    expect(indicatorCentre, greaterThan(tab0.center.dx));
    expect(indicatorCentre, lessThan(tab1.center.dx));
  });

  testWidgets('选中背景块和下划线一起滑动', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: const [AppStyleTokens.classic()]),
        home: const Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: ClassicHomeTabBar(
              selectedIndex: 0,
              onSelect: _noop,
              progress: 0.5,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final indicator = tester.getRect(find.byKey(indicatorKey));
    final block = tester.getRect(find.byKey(blockKey));

    // 两者一起移动：背景块的中心也在两个标签中心之间，且与下划线同向。
    final tab0 = tester.getRect(find.byKey(const ValueKey('home_category_0')));
    final tab1 = tester.getRect(find.byKey(const ValueKey('home_category_1')));
    expect(block.center.dx, greaterThan(tab0.center.dx));
    expect(block.center.dx, lessThan(tab1.center.dx));
    // 下划线在背景块之内。
    expect(indicator.center.dx, greaterThan(block.left));
    expect(indicator.center.dx, lessThan(block.right));
  });

  testWidgets('进度为 null 时退回点按动画，指示条停在选中标签', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: const [AppStyleTokens.classic()]),
        home: const Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: ClassicHomeTabBar(selectedIndex: 2, onSelect: _noop),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final tab2 = tester.getRect(find.byKey(const ValueKey('home_category_2')));
    final indicator = tester.getRect(find.byKey(indicatorKey));
    expect(indicator.center.dx, moreOrLessEquals(tab2.center.dx, epsilon: 1));
  });

  testWidgets('手指停住后下划线不再自己追一段（松手前的“弹一下”）', (tester) async {
    await pumpHost(tester);

    // 按住拖到两标签之间就停住，不松手。
    final gesture = await tester.startGesture(const Offset(600, 500));
    for (var i = 0; i < 6; i++) {
      await gesture.moveBy(const Offset(-30, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    final during = tester.getRect(find.byKey(indicatorKey)).center.dx;

    // 手指不动，多等一帧也不该再移动：隐式动画会在这 300ms 里继续追赶，
    // 屏幕上就是下划线自己往目标位置“弹”过去。
    await tester.pump(const Duration(milliseconds: 400));
    final later = tester.getRect(find.byKey(indicatorKey)).center.dx;
    expect(
      later,
      moreOrLessEquals(during, epsilon: 1.5),
      reason: '跟手阶段不能有残余的补间动画',
    );

    await gesture.up();
    await tester.pumpAndSettle();
  });
}

void _noop(int index) {}
