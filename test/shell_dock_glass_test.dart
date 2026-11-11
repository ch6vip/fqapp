import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/services/app_theme_style.dart';
import 'package:fqapp/widgets/shell_dock.dart';
import 'package:fqapp/widgets/wenku/glass_dock.dart';
import 'package:fqapp/widgets/wenku/src/easy_glass.dart';

/// 档案风格 GlassDock 的 animating 降级（评审遗留 Minor #5）：页面切换
/// 动画期间与 staticMaterial 同走轻量预设——胶囊折射（EasyGlassSurface）
/// 与 underlay 边缘模糊一并跳过，动画结束自动恢复；dock 自身交互与
/// State 不受预设切换影响。
void main() {
  setUp(() {
    einkModeNotifier.value = false;
    oledModeNotifier.value = false;
  });
  tearDown(() {
    einkModeNotifier.value = false;
    oledModeNotifier.value = false;
  });

  Widget app(ValueNotifier<bool> animating) => MaterialApp(
    theme: AppTheme.createTheme(Brightness.light, style: AppThemeStyle.archive),
    themeAnimationDuration: Duration.zero,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: true),
      child: child!,
    ),
    home: Scaffold(
      bottomNavigationBar: ValueListenableBuilder<bool>(
        valueListenable: animating,
        builder: (context, value, _) => ShellDock(
          selectedIndex: 0,
          onSelected: (_) {},
          overVideo: false,
          staticMaterial: false,
          animating: value,
        ),
      ),
    ),
  );

  testWidgets('档案 dock 动画期间跳过折射与边缘模糊，结束后恢复', (tester) async {
    final animating = ValueNotifier<bool>(false);
    addTearDown(animating.dispose);
    await tester.pumpWidget(app(animating));
    await tester.pumpAndSettle();

    // 静止态：underlay 边缘模糊与胶囊实时折射都在。
    expect(find.byKey(const ValueKey('dock-underlay')), findsOneWidget);
    expect(find.byType(EasyGlassSurface), findsOneWidget);
    final stateBefore = tester.state(find.byType(GlassDock));

    // 动画进行中：轻量预设关掉 glass/edgeBlur，两者一并消失，
    // 但 dock 本体保留（降级的是材质，不是导航）。
    animating.value = true;
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('dock-underlay')), findsNothing);
    expect(find.byType(EasyGlassSurface), findsNothing);
    expect(find.byType(GlassDock), findsOneWidget);
    // 预设切换只换材质分支，不能把 dock 的 State 换掉（选中/拖动状态
    // 会在动画结束后丢失）。
    expect(tester.state(find.byType(GlassDock)), same(stateBefore));

    // 动画结束：实时效果自动恢复。
    animating.value = false;
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('dock-underlay')), findsOneWidget);
    expect(find.byType(EasyGlassSurface), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('档案 dock 动画期间仍可点按切换，staticMaterial 行为不变', (
    tester,
  ) async {
    final animating = ValueNotifier<bool>(true);
    addTearDown(animating.dispose);
    var selected = -1;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.createTheme(
          Brightness.light,
          style: AppThemeStyle.archive,
        ),
        themeAnimationDuration: Duration.zero,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: Scaffold(
          bottomNavigationBar: ValueListenableBuilder<bool>(
            valueListenable: animating,
            builder: (context, value, _) => ShellDock(
              selectedIndex: 0,
              onSelected: (index) => selected = index,
              overVideo: false,
              staticMaterial: false,
              animating: value,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 降级材质不拦交互：动画期间点「书架」照常回调。
    await tester.tap(
      find.descendant(of: find.byType(GlassDock), matching: find.text('书架')),
    );
    await tester.pumpAndSettle();
    expect(selected, 2);

    // staticMaterial 单独成立时（视频流 / OLED）同样没有 underlay，
    // 与 animating 无关——既有契约不被本次改动破坏。
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.createTheme(
          Brightness.light,
          style: AppThemeStyle.archive,
        ),
        themeAnimationDuration: Duration.zero,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: Scaffold(
          bottomNavigationBar: ShellDock(
            selectedIndex: 0,
            onSelected: (_) {},
            overVideo: false,
            staticMaterial: true,
            animating: false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('dock-underlay')), findsNothing);
    expect(find.byType(GlassDock), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}