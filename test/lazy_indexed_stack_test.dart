import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/widgets/lazy_indexed_stack.dart';

void main() {
  testWidgets(
    'tabs mount on demand and retain scroll position when revisited',
    (tester) async {
      final mounted = <int>[];
      final disposed = <int>[];
      final keys = List.generate(3, (_) => GlobalKey<_TabProbeState>());
      final children = [
        for (var index = 0; index < 3; index++)
          _TabProbe(
            key: keys[index],
            id: index,
            onMount: mounted.add,
            onDispose: disposed.add,
          ),
      ];
      Widget app(int index) => MaterialApp(
        home: LazyIndexedStack(index: index, children: children),
      );

      await tester.pumpWidget(app(0));
      expect(mounted, [0]);
      expect(keys[1].currentState, isNull);
      final first = keys[0].currentState!;
      first.scroll.jumpTo(240);
      await tester.pump();
      await tester.pumpWidget(app(1));
      expect(mounted, [0, 1]);
      expect(disposed, isEmpty);
      expect(keys[2].currentState, isNull);
      await tester.pumpWidget(app(0));
      expect(keys[0].currentState, same(first));
      expect(first.scroll.offset, 240);
      expect(mounted, [0, 1]);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(disposed, unorderedEquals([0, 1]));
    },
  );

  testWidgets('hidden tabs and an offstage parent stop animation ticks', (
    tester,
  ) async {
    final keys = List.generate(2, (_) => GlobalKey<_TabProbeState>());
    final children = [
      for (var index = 0; index < 2; index++)
        _TabProbe(key: keys[index], id: index),
    ];
    Widget app(int index, {bool enabled = true}) => MaterialApp(
      home: TickerMode(
        enabled: enabled,
        child: LazyIndexedStack(index: index, children: children),
      ),
    );

    await tester.pumpWidget(app(0));
    await tester.pump(const Duration(milliseconds: 100));
    final first = keys[0].currentState!;
    expect(first.ticks, greaterThan(0));
    await tester.pumpWidget(app(1));
    final hiddenTicks = first.ticks;
    final second = keys[1].currentState!;
    await tester.pump(const Duration(milliseconds: 100));
    expect(first.ticks, hiddenTicks);
    expect(second.ticks, greaterThan(0));
    await tester.pumpWidget(app(1, enabled: false));
    final parentHiddenTicks = second.ticks;
    await tester.pump(const Duration(milliseconds: 100));
    expect(second.ticks, parentHiddenTicks);
    expect(first.ticks, hiddenTicks);
    await tester.pumpWidget(app(0));
    await tester.pump(const Duration(milliseconds: 100));
    expect(first.ticks, greaterThan(hiddenTicks));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });
}

class _TabProbe extends StatefulWidget {
  final int id;
  final ValueChanged<int>? onMount;
  final ValueChanged<int>? onDispose;

  const _TabProbe({super.key, required this.id, this.onMount, this.onDispose});

  @override
  State<_TabProbe> createState() => _TabProbeState();
}

class _TabProbeState extends State<_TabProbe>
    with SingleTickerProviderStateMixin {
  final scroll = ScrollController();
  late final AnimationController animation;
  int ticks = 0;

  @override
  void initState() {
    super.initState();
    widget.onMount?.call(widget.id);
    animation =
        AnimationController(vsync: this, duration: const Duration(seconds: 1))
          ..addListener(() => ticks++)
          ..repeat();
  }

  @override
  Widget build(BuildContext context) => ListView.builder(
    controller: scroll,
    itemExtent: 50,
    itemCount: 100,
    itemBuilder: (context, index) => Text('${widget.id}:$index'),
  );

  @override
  void dispose() {
    animation.dispose();
    scroll.dispose();
    widget.onDispose?.call(widget.id);
    super.dispose();
  }
}
