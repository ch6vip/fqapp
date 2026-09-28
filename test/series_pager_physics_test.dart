import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/pages/series_pager_physics.dart';

/// 官方翻页吸附的恒速滑行（`LinearSmoothScroller` 100ms/英寸）：
/// 密度相消后恒为 1600 逻辑像素/秒，到位即停。
void main() {
  group('SeriesPagerGlideSimulation', () {
    test('glides at a constant 1600 logical px per second', () {
      final sim = SeriesPagerGlideSimulation(0, 800);
      expect(sim.x(0), 0);
      expect(sim.x(0.25), 400); // 1600 * 0.25s
      expect(sim.x(0.5), 800);
      expect(sim.dx(0.25), 1600);
      expect(sim.isDone(0.5), isTrue);
    });

    test('a full page takes about 500ms like the official scroller', () {
      final sim = SeriesPagerGlideSimulation(0, 800);
      expect(sim.x(0.4), 640);
      expect(sim.isDone(0.4), isFalse);
      // 800px / 1600px/s = 0.5s。
      expect(sim.isDone(0.51), isTrue);
      expect(sim.x(0.51), 800);
    });

    test('negative distance glides the other way', () {
      final sim = SeriesPagerGlideSimulation(800, -800);
      expect(sim.x(0.25), 400);
      expect(sim.x(0.5), 0);
      expect(sim.dx(0.25), -1600);
    });

    test('tiny distances stop almost immediately without overshoot', () {
      final sim = SeriesPagerGlideSimulation(399.0, 1.0);
      expect(sim.isDone(0.01), isTrue);
      expect(sim.x(1), 400);
    });
  });

  group('SeriesPagerScrollPhysics on a PageView', () {
    Future<PageController> pumpFeed(WidgetTester tester) async {
      final controller = PageController();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PageView.builder(
              controller: controller,
              scrollDirection: Axis.vertical,
              physics: const SeriesPagerScrollPhysics(),
              itemCount: 10,
              itemBuilder: (_, index) =>
                  SizedBox.expand(key: ValueKey('page-$index')),
            ),
          ),
        ),
      );
      return controller;
    }

    testWidgets('a fling turns exactly one page regardless of speed', (
      tester,
    ) async {
      final controller = await pumpFeed(tester);
      // 官方 PagerSnapHelper：无论多快都只翻一页（默认弹簧会飞过多页）。
      await tester.fling(
        find.byKey(const ValueKey('page-0')),
        const Offset(0, -100),
        8000,
      );
      await tester.pumpAndSettle();
      expect(controller.page, 1);
    });

    testWidgets('a slow release snaps to the nearest page', (tester) async {
      final controller = await pumpFeed(tester);
      // 320/600 ≈ 0.53 页，就近吸附到第 1 页（官方 snapToTargetExistingView）。
      await tester.dragFrom(const Offset(400, 300), const Offset(0, -320));
      await tester.pumpAndSettle();
      expect(controller.page, 1);
      // 反向慢拖 320/600 ≈ 0.53 页，回到第 0 页（250px 时 page=0.58 仍就近取 1）。
      await tester.dragFrom(const Offset(400, 300), const Offset(0, 320));
      await tester.pumpAndSettle();
      expect(controller.page, 0);
    });
  });
}
