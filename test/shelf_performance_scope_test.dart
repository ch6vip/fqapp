import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/widgets/shelf/shelf_performance_scope.dart';
import 'package:fqapp/widgets/wenku/src/performance_preferences.dart';

class _Snapshot {
  const _Snapshot({
    required this.shelf3d,
    required this.glass,
    required this.motion,
    required this.disableAnimations,
    required this.reduceMotion,
  });
  final bool shelf3d;
  final bool glass;
  final bool motion;
  final bool disableAnimations;
  final bool reduceMotion;
}

class _Probe extends StatelessWidget {
  const _Probe({required this.onRead});
  final ValueChanged<_Snapshot> onRead;

  @override
  Widget build(BuildContext context) {
    final preferences = PerformanceScope.of(context);
    onRead(
      _Snapshot(
        shelf3d: preferences.shelf3d,
        glass: preferences.glass,
        motion: preferences.motion,
        disableAnimations: MediaQuery.disableAnimationsOf(context),
        reduceMotion: PerformanceScope.reduceMotionOf(context),
      ),
    );
    return const SizedBox.shrink();
  }
}

void main() {
  setUp(() => einkModeNotifier.value = false);
  tearDown(() => einkModeNotifier.value = false);

  Future<_Snapshot> pumpScope(
    WidgetTester tester, {
    required bool shelf3d,
    bool? reduceMotion,
    PerformancePreferences outer = const PerformancePreferences(),
    bool mediaDisableAnimations = false,
  }) async {
    late _Snapshot result;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: mediaDisableAnimations),
          child: PerformanceScope(
            preferences: outer,
            child: ShelfPerformanceScope(
              shelf3d: shelf3d,
              reduceMotion: reduceMotion,
              child: _Probe(onRead: (value) => result = value),
            ),
          ),
        ),
      ),
    );
    return result;
  }

  testWidgets('shelf3d=false 只关闭 shelf3d，保留外层效果', (tester) async {
    final on = await pumpScope(
      tester,
      shelf3d: true,
      outer: const PerformancePreferences(
        enabled: true,
        effects: {PerformanceEffect.glass, PerformanceEffect.motion},
      ),
    );
    expect(on.shelf3d, isTrue);
    expect(on.glass, isTrue);
    expect(on.motion, isTrue);

    final off = await pumpScope(
      tester,
      shelf3d: false,
      outer: const PerformancePreferences(
        enabled: true,
        effects: {PerformanceEffect.glass, PerformanceEffect.motion},
      ),
    );
    expect(off.shelf3d, isFalse);
    expect(off.glass, isTrue);
    expect(off.motion, isTrue);
  });

  testWidgets('performance preset 未启用时原样保留', (tester) async {
    final result = await pumpScope(tester, shelf3d: false);
    expect(result.shelf3d, isFalse);
    expect(result.glass, isTrue);
    expect(result.motion, isTrue);
  });

  testWidgets('墨水屏强制平面并关闭动效', (tester) async {
    einkModeNotifier.value = true;
    final result = await pumpScope(tester, shelf3d: true);
    expect(result.shelf3d, isFalse);
    expect(result.disableAnimations, isTrue);
  });

  testWidgets('reduceMotion 透传', (tester) async {
    final result = await pumpScope(tester, shelf3d: true, reduceMotion: true);
    expect(result.reduceMotion, isTrue);
    expect(result.disableAnimations, isTrue);
  });

  testWidgets('显式 reduceMotion=false 覆盖 MediaQuery', (tester) async {
    final result = await pumpScope(
      tester,
      shelf3d: true,
      reduceMotion: false,
      mediaDisableAnimations: true,
    );
    expect(result.reduceMotion, isFalse);
    expect(result.disableAnimations, isFalse);
  });

  test('preferencesFor 在关闭时移除 shelf3d 且保留其它效果', () {
    const outer = PerformancePreferences(
      enabled: true,
      effects: {PerformanceEffect.glass, PerformanceEffect.shelf3d},
    );
    final off = ShelfPerformanceScope.preferencesFor(outer, shelf3d: false);
    expect(off.shelf3d, isFalse);
    expect(off.glass, isTrue);
    final on = ShelfPerformanceScope.preferencesFor(outer, shelf3d: true);
    expect(on.shelf3d, isTrue);
    expect(on.glass, isTrue);
  });

  test('关闭的预设被物化为全效果；调用方只应按 allows 读取', () {
    final off = ShelfPerformanceScope.preferencesFor(
      const PerformancePreferences(),
      shelf3d: false,
    );
    // `.enabled` is not a lightweight-mode flag for the merged preset.
    expect(off.enabled, isTrue);
    for (final effect in PerformanceEffect.values) {
      expect(
        off.allows(effect),
        effect != PerformanceEffect.shelf3d,
        reason: '$effect',
      );
    }
  });
}
