import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/widgets/wenku/wenku_reveal.dart';

Widget _host({
  required Animation<double> animation,
  required bool crossfade,
  bool disableAnimations = false,
}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: disableAnimations),
    child: Scaffold(
      body: SizedBox(
        width: 200,
        height: 40,
        child: LoadingHandoff(
          animation: animation,
          crossfade: crossfade,
          start: .2,
          end: .75,
          placeholder: const Text('骨架'),
          child: const Text('内容'),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('crossfade 在入场中同时淡入内容、淡出骨架', (tester) async {
    final clock = AnimationController(vsync: const TestVSync(), value: .5);
    addTearDown(clock.dispose);
    await tester.pumpWidget(_host(animation: clock, crossfade: true));

    expect(find.text('骨架'), findsOneWidget);
    expect(find.text('内容'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(LoadingHandoff),
        matching: find.byType(FadeTransition),
      ),
      findsNWidgets(2),
    );
  });

  testWidgets('crossfade 完成后移除骨架', (tester) async {
    final clock = AnimationController(vsync: const TestVSync(), value: 1);
    addTearDown(clock.dispose);
    await tester.pumpWidget(_host(animation: clock, crossfade: true));

    expect(find.text('内容'), findsOneWidget);
    expect(find.text('骨架'), findsNothing);
  });

  testWidgets('非 crossfade 使用裁剪剩余骨架', (tester) async {
    final clock = AnimationController(vsync: const TestVSync(), value: .5);
    addTearDown(clock.dispose);
    await tester.pumpWidget(_host(animation: clock, crossfade: false));

    expect(find.text('骨架'), findsOneWidget);
    expect(find.text('内容'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(LoadingHandoff),
        matching: find.byType(FadeTransition),
      ),
      findsNothing,
    );
  });

  testWidgets('disableAnimations 直接显示内容', (tester) async {
    final clock = AnimationController(vsync: const TestVSync(), value: .2);
    addTearDown(clock.dispose);
    await tester.pumpWidget(
      _host(animation: clock, crossfade: true, disableAnimations: true),
    );

    expect(find.text('内容'), findsOneWidget);
    expect(find.text('骨架'), findsNothing);
  });
}
