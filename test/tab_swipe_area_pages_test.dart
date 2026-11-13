import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/widgets/tab_swipe_area.dart';

Widget _app({
  required int index,
  required int count,
  ValueChanged<int>? onSelect,
  ValueChanged<bool>? onScrollState,
  ValueChanged<double>? onProgress,
}) {
  return MaterialApp(
    home: Scaffold(
      body: TabSwipeArea.pages(
        index: index,
        count: count,
        onSelect: onSelect ?? (_) {},
        onScrollStateChanged: onScrollState,
        onProgress: onProgress,
        pageBuilder: (context, i) => Center(child: Text('page $i')),
      ),
    ),
  );
}

void main() {
  testWidgets('外部换下标会滚到目标页并把进度归零', (tester) async {
    final progress = <double>[];
    await tester.pumpWidget(_app(index: 0, count: 3, onProgress: progress.add));
    await tester.pumpAndSettle();
    expect(find.text('page 0'), findsOneWidget);

    await tester.pumpWidget(_app(index: 2, count: 3, onProgress: progress.add));
    await tester.pumpAndSettle();

    expect(find.text('page 2'), findsOneWidget);
    expect(find.text('page 0'), findsNothing);
    expect(progress.last, 0);
  });

  testWidgets('标签数变少时把越界的页码收回来，不抛异常', (tester) async {
    await tester.pumpWidget(_app(index: 4, count: 5));
    await tester.pumpAndSettle();
    expect(find.text('page 4'), findsOneWidget);

    await tester.pumpWidget(_app(index: 1, count: 3));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('page 1'), findsOneWidget);
  });

  testWidgets('快速连换两个目标只落最后一页', (tester) async {
    await tester.pumpWidget(_app(index: 0, count: 3));
    await tester.pumpAndSettle();

    await tester.pumpWidget(_app(index: 2, count: 3));
    await tester.pump();
    await tester.pumpWidget(_app(index: 0, count: 3));
    await tester.pumpAndSettle();

    expect(find.text('page 0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('回程动画中父级再次 build 不会重复排程、不会串页', (tester) async {
    final selects = <int>[];
    var index = 0;
    Widget build() => _app(index: index, count: 3, onSelect: selects.add);

    await tester.pumpWidget(build());
    await tester.pumpAndSettle();

    // A→C：动画开始。
    index = 2;
    await tester.pumpWidget(build());
    await tester.pump();

    // 立刻回 A：回程动画开始。
    index = 0;
    await tester.pumpWidget(build());
    await tester.pump(const Duration(milliseconds: 20));

    // 回程途中父级又 build（短剧切频道时 provider 连续发布状态就会这样）：
    // 目标没变，不能再排一次 animateToPage，否则旧 future 立刻完成并提前
    // 清闩，页面在半路就被 `round()` 报成 1 或 2。
    for (var i = 0; i < 4; i++) {
      await tester.pumpWidget(build());
      await tester.pump(const Duration(milliseconds: 40));
    }
    await tester.pumpAndSettle();

    expect(selects, isEmpty, reason: '中途不该上报任何一次切页');
    expect(find.text('page 0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('外部换页与标签数收缩同一帧发生时不抛异常', (tester) async {
    await tester.pumpWidget(_app(index: 4, count: 5));
    await tester.pumpAndSettle();

    // 一帧里同时换下标并把 count 缩到 3：控制器还必须按旧页数收尾。
    await tester.pumpWidget(_app(index: 0, count: 3));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('page 0'), findsOneWidget);
  });

  testWidgets('关闭动画时外部换页直接跳页，结束信号照常到达', (tester) async {
    final states = <bool>[];
    Widget motionless(int index) => MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(
          size: Size(800, 600),
          disableAnimations: true,
        ),
        child: TabSwipeArea.pages(
          index: index,
          count: 3,
          onSelect: (_) {},
          onScrollStateChanged: states.add,
          pageBuilder: (context, i) => Center(child: Text('page $i')),
        ),
      ),
    );

    await tester.pumpWidget(motionless(0));
    await tester.pumpAndSettle();
    await tester.pumpWidget(motionless(2));
    await tester.pumpAndSettle();

    expect(find.text('page 2'), findsOneWidget);
    // `jumpToPage` 也会走一次 ScrollStart/End；关键是**最后必须是 false**，
    // 否则外面预置的「横滑中」闩会一直挂着。
    expect(states.last, isFalse);
  });

  testWidgets('外部换页动画在途时 pager 被销毁不抛异常', (tester) async {
    await tester.pumpWidget(_app(index: 0, count: 3));
    await tester.pumpAndSettle();

    await tester.pumpWidget(_app(index: 2, count: 3));
    await tester.pump(const Duration(milliseconds: 60)); // 动画进行中

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets('滚动中被销毁要补发「横滑结束」，闩不会永久挂住', (tester) async {
    final states = <bool>[];
    await tester.pumpWidget(
      _app(index: 0, count: 3, onScrollState: states.add),
    );
    await tester.pumpAndSettle();

    // 按住并横移：ScrollStart 已经把状态置 true，但**不松手**，
    // 所以不会自动收到 ScrollEnd。
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(PageView)),
    );
    await gesture.moveBy(const Offset(-140, 0));
    await tester.pump();
    expect(states.last, isTrue);

    // 频道表回包换 key 一类的情况：整棵 pager 被换掉。
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();

    expect(states.last, isFalse);
    await gesture.up();
  });
}
