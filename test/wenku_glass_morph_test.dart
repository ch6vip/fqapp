import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart' show LiquidGlassLens;

import 'package:fqapp/widgets/wenku/src/easy_glass.dart';
import 'package:fqapp/widgets/wenku/src/glass_morph.dart';

Widget _wrap(Widget child) => MaterialApp(
  home: Scaffold(
    body: Center(child: SizedBox(width: 240, height: 160, child: child)),
  ),
);

EasyGlassSurface _surface({WenkuGlassMorph? morph, bool physical = true}) =>
    EasyGlassSurface(
      radius: 24,
      thickness: 20,
      blur: 0,
      refractiveIndex: 1.45,
      tint: const Color(0x00000000),
      emission: 0,
      activation: 0,
      physicalOptics: physical,
      morph: morph,
      child: const Text('菜单内容'),
    );

void main() {
  test('resolve interpolates the material from control to overlay', () {
    final controller = AnimationController(
      vsync: const TestVSync(),
      duration: const Duration(milliseconds: 300),
    );
    addTearDown(controller.dispose);
    final morph = WenkuGlassMorph(
      animation: controller,
      radius: 12,
      thickness: 6,
      blur: 3,
    );

    expect(morph.progress, 0);
    expect(morph.resolve(12, 28), 12);
    expect(morph.resolve(6, 20), 6);
    expect(morph.resolve(3, 12), 3);

    controller.value = 1;
    expect(morph.progress, 1);
    expect(morph.resolve(12, 28), 28);
    expect(morph.resolve(6, 20), 20);
    expect(morph.resolve(3, 12), 12);

    controller.value = .5;
    final progress = Curves.easeOutCubic.transform(.5);
    expect(morph.progress, closeTo(progress, 1e-9));
    expect(morph.resolve(12, 28), closeTo(12 + 16 * progress, 1e-9));
    expect(morph.resolve(3, 12), closeTo(3 + 9 * progress, 1e-9));
  });

  testWidgets('preserveOptics keeps menu content above a morphing lens', (
    tester,
  ) async {
    final controller = AnimationController(
      vsync: const TestVSync(),
      duration: const Duration(milliseconds: 300),
      value: 1,
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _wrap(
        _surface(
          morph: WenkuGlassMorph(
            animation: controller,
            radius: 12,
            thickness: 6,
            blur: 0,
          ),
        ),
      ),
    );

    expect(find.text('菜单内容'), findsOneWidget);
    expect(find.byType(LiquidGlassLens), findsOneWidget);
    final settled = tester.widget<LiquidGlassLens>(
      find.byType(LiquidGlassLens),
    );
    expect(settled.style.shape!.cornerRadius, 24);
    expect(settled.style.refractionWidth, 20);
  });

  testWidgets('the lens follows the morph clock each frame', (tester) async {
    final controller = AnimationController(
      vsync: const TestVSync(),
      duration: const Duration(milliseconds: 300),
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _wrap(
        _surface(
          morph: WenkuGlassMorph(
            animation: controller,
            radius: 12,
            thickness: 6,
            blur: 6,
          ),
        ),
      ),
    );

    controller.value = .5;
    await tester.pump();
    final mid = tester.widget<LiquidGlassLens>(find.byType(LiquidGlassLens));
    final progress = Curves.easeOutCubic.transform(.5);
    expect(mid.style.shape!.cornerRadius, closeTo(12 + 12 * progress, 1e-9));
    expect(mid.style.refractionWidth, closeTo(6 + 14 * progress, 1e-9));
    expect(mid.style.blur, closeTo(6 * (1 - progress), 1e-9));

    controller.value = 1;
    await tester.pump();
    final end = tester.widget<LiquidGlassLens>(find.byType(LiquidGlassLens));
    expect(end.style.shape!.cornerRadius, 24);
    expect(end.style.refractionWidth, 20);
    expect(end.style.blur, 0);
  });

  testWidgets('a null morph keeps the previous static material', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(_surface()));
    expect(find.text('菜单内容'), findsOneWidget);
    final lens = tester.widget<LiquidGlassLens>(find.byType(LiquidGlassLens));
    expect(lens.style.shape!.cornerRadius, 24);
    expect(lens.style.refractionWidth, 20);
  });

  testWidgets('non-physical optics still show the menu content', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(_surface(physical: false)));
    expect(find.text('菜单内容'), findsOneWidget);
    expect(find.byType(LiquidGlassLens), findsOneWidget);
  });
}
