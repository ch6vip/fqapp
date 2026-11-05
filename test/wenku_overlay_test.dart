import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart' show LiquidGlassLens;

import 'package:fqapp/widgets/wenku/src/glass_overlay_motion.dart';
import 'package:fqapp/widgets/wenku/wenku_glass.dart';
import 'package:fqapp/widgets/wenku/wenku_overlay.dart';
import 'package:fqapp/widgets/wenku/wenku_theme.dart';

Widget _host(
  Widget child, {
  ThemeData? theme,
  bool disableAnimations = false,
  bool highContrast = false,
}) => MaterialApp(
  theme: theme,
  builder: (context, widget) {
    final media = MediaQuery.of(context);
    return MediaQuery(
      data: media.copyWith(
        disableAnimations: disableAnimations,
        highContrast: highContrast,
      ),
      child: widget!,
    );
  },
  home: Scaffold(
    body: Center(
      child: Builder(
        builder: (context) => SizedBox(
          key: const Key('anchor'),
          width: 60,
          height: 40,
          child: child,
        ),
      ),
    ),
  ),
);

class _RouteObserver extends NavigatorObserver {
  final List<Route<dynamic>> pushed = [];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route);
    super.didPush(route, previousRoute);
  }
}

Future<Future<T?>> _openSheet<T>(
  WidgetTester tester,
  WidgetBuilder builder, {
  bool reduceMotion = false,
}) async {
  final context = tester.element(find.byKey(const Key('anchor')));
  final future = showJellySheet<T>(
    context: context,
    reduceMotion: reduceMotion,
    builder: builder,
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  return future;
}

Future<Future<T?>> _openMenu<T>(
  WidgetTester tester,
  WidgetBuilder builder, {
  bool reduceMotion = false,
  bool preferBelow = false,
}) async {
  final context = tester.element(find.byKey(const Key('anchor')));
  final future = showGlassMenu<T>(
    context: context,
    reduceMotion: reduceMotion,
    preferBelow: preferBelow,
    builder: builder,
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  return future;
}

void main() {
  testWidgets('showJellySheet returns the selected value and ignores taps '
      'outside the sheet', (tester) async {
    await tester.pumpWidget(_host(const SizedBox.shrink()));
    final confirmed = await _openSheet<bool>(
      tester,
      (sheet) => Padding(
        padding: const EdgeInsets.all(24),
        child: TextButton(
          onPressed: () => Navigator.pop(sheet, true),
          child: const Text('确定'),
        ),
      ),
    );
    expect(find.text('确定'), findsOneWidget);
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(find.text('确定'), findsNothing);
    expect(await confirmed, isTrue);

    final cancelled = await _openSheet<bool>(
      tester,
      (sheet) => const Padding(padding: EdgeInsets.all(24), child: Text('不能点')),
    );
    expect(find.text('不能点'), findsOneWidget);
    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();
    expect(find.text('不能点'), findsNothing);
    expect(await cancelled, isNull);
  });

  testWidgets('overlay route duration follows reduceMotion', (tester) async {
    final observer = _RouteObserver();
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [observer],
        home: const Scaffold(
          body: Center(
            child: SizedBox(key: Key('anchor'), child: Text('源')),
          ),
        ),
      ),
    );
    final context = tester.element(find.byKey(const Key('anchor')));
    unawaited(
      showJellySheet<void>(
        context: context,
        reduceMotion: true,
        builder: (_) => const SizedBox(height: 80, child: Text('弹层')),
      ),
    );
    await tester.pump();
    expect(observer.pushed, isNotEmpty);
    final route = observer.pushed.whereType<TransitionRoute<dynamic>>().last;
    expect(route.transitionDuration, Duration.zero);
    expect(route.reverseTransitionDuration, Duration.zero);
    await tester.pumpAndSettle();
    expect(find.text('弹层'), findsOneWidget);
  });

  testWidgets('host disableAnimations also yields a zero-duration route', (
    tester,
  ) async {
    final observer = _RouteObserver();
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [observer],
        builder: (context, widget) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: widget!,
        ),
        home: const Scaffold(
          body: Center(
            child: SizedBox(key: Key('anchor'), child: Text('源')),
          ),
        ),
      ),
    );
    final context = tester.element(find.byKey(const Key('anchor')));
    final future = showJellySheet<void>(
      context: context,
      builder: (_) => const SizedBox(height: 80, child: Text('弹层')),
    );
    await tester.pump();
    final route = observer.pushed.whereType<TransitionRoute<dynamic>>().last;
    expect(route.transitionDuration, Duration.zero);
    await tester.pumpAndSettle();
    expect(find.text('弹层'), findsOneWidget);
    Navigator.of(context).pop();
    await tester.pumpAndSettle();
    await future;
  });

  testWidgets('a menu is 248dp wide and right-aligned to its anchor', (
    tester,
  ) async {
    await tester.pumpWidget(_host(const SizedBox.shrink()));
    final anchor = tester.getRect(find.byKey(const Key('anchor')));
    await _openMenu<void>(
      tester,
      (_) => const SizedBox(height: 120, child: Text('菜单内容')),
    );
    final top = tester.getRect(find.byType(GlassMenuStretch));
    expect(top.width, 248);
    expect(top.top, anchor.top);
    expect(top.right, anchor.right);
  });

  testWidgets('a bottom-anchored menu flips to the trigger bottom', (
    tester,
  ) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomRight,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Builder(
                builder: (value) {
                  context = value;
                  return const SizedBox(
                    key: Key('anchor'),
                    width: 60,
                    height: 40,
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    final anchor = tester.getRect(find.byKey(const Key('anchor')));
    final future = showGlassMenu<void>(
      context: context,
      builder: (_) => const SizedBox(height: 160, child: Text('菜单内容')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    final menu = tester.getRect(find.byType(GlassMenuStretch));
    expect(menu.width, 248);
    expect(menu.bottom, closeTo(anchor.bottom, .01));
    expect(menu.top, lessThan(anchor.top));
    expect(menu.right, anchor.right);
    Navigator.of(context).pop();
    await tester.pumpAndSettle();
    await future;
  });

  testWidgets('menu stretch paints without relayout while opening', (
    tester,
  ) async {
    await tester.pumpWidget(_host(const SizedBox.shrink()));
    final context = tester.element(find.byKey(const Key('anchor')));
    unawaited(
      showGlassMenu<void>(
        context: context,
        builder: (_) => const SizedBox(height: 120, child: Text('菜单内容')),
      ),
    );
    await tester.pump();
    final stretch = tester.renderObject<GlassMenuStretchRender>(
      find.byType(GlassMenuStretch),
    );
    final layouts = stretch.debugLayoutCount;
    final paints = stretch.debugPaintCount;
    await tester.pump(const Duration(milliseconds: 50));
    expect(stretch.debugLayoutCount, layouts);
    expect(stretch.debugPaintCount, greaterThan(paints));
  });

  testWidgets('an open menu hides its anchor from pointers and semantics', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: GlassMenuAnchor(
              child: Builder(
                builder: (value) {
                  context = value;
                  return SizedBox(
                    key: const Key('anchor'),
                    width: 60,
                    height: 40,
                    child: Semantics(label: '触发器', child: const Text('触发')),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    final future = showGlassMenu<void>(
      context: context,
      builder: (_) => const SizedBox(height: 80, child: Text('菜单内容')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    final opacity = tester.widget<Opacity>(
      find
          .descendant(
            of: find.byType(GlassMenuAnchor),
            matching: find.byType(Opacity),
          )
          .first,
    );
    expect(opacity.opacity, 0);
    final ignore = tester.widget<IgnorePointer>(
      find
          .descendant(
            of: find.byType(GlassMenuAnchor),
            matching: find.byType(IgnorePointer),
          )
          .first,
    );
    expect(ignore.ignoring, isTrue);
    expect(find.bySemanticsLabel('触发器'), findsNothing);

    Navigator.of(context).pop();
    await tester.pumpAndSettle();
    await future;
    semantics.dispose();
  });

  testWidgets('a liquid-glass trigger captures its material for the menu', (
    tester,
  ) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Builder(
              builder: (value) {
                context = value;
                return const LiquidGlass(
                  radius: 24,
                  thickness: 20,
                  child: SizedBox(
                    key: Key('anchor'),
                    width: 60,
                    height: 40,
                    child: Text('触发'),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
    expect(find.byType(LiquidGlass), findsOneWidget);
    final future = showGlassMenu<void>(
      context: context,
      builder: (_) => const SizedBox(height: 80, child: Text('菜单内容')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(GlassMenuContents), findsOneWidget);
    Navigator.of(context).pop();
    await tester.pumpAndSettle();
    await future;
  });

  testWidgets('a second menu from the same context returns null', (
    tester,
  ) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Builder(
              builder: (value) {
                context = value;
                return const SizedBox(
                  key: Key('anchor'),
                  width: 60,
                  height: 40,
                );
              },
            ),
          ),
        ),
      ),
    );
    final first = showGlassMenu<void>(
      context: context,
      builder: (_) => const SizedBox(height: 80, child: Text('一')),
    );
    final second = await showGlassMenu<Object?>(
      context: context,
      builder: (_) => const SizedBox(height: 80, child: Text('二')),
    );
    expect(second, isNull);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('一'), findsOneWidget);
    Navigator.of(context).pop();
    await tester.pumpAndSettle();
    await first;
  });

  testWidgets('disableAnimations skips the stretch transition', (tester) async {
    await tester.pumpWidget(
      _host(const SizedBox.shrink(), disableAnimations: true),
    );
    // Verify the rendered tree: no stretch paint plane is installed.
    await _openMenu<void>(
      tester,
      (_) => const SizedBox(height: 80, child: Text('菜单内容')),
      reduceMotion: true,
    );
    expect(find.byType(GlassMenuStretch), findsNothing);
    expect(find.text('菜单内容'), findsOneWidget);
  });

  testWidgets('high contrast and e-ink render an opaque plate', (tester) async {
    await tester.pumpWidget(_host(const SizedBox.shrink()));
    await _openSheet<void>(
      tester,
      (_) => const SizedBox(height: 120, child: Text('玻璃弹层')),
    );
    expect(find.byType(LiquidGlassLens), findsOneWidget);
    Navigator.of(tester.element(find.byKey(const Key('anchor')))).pop();
    await tester.pumpAndSettle();

    await tester.pumpWidget(_host(const SizedBox.shrink(), highContrast: true));
    await _openSheet<void>(
      tester,
      (_) => const SizedBox(height: 120, child: Text('高对比弹层')),
    );
    expect(find.text('高对比弹层'), findsOneWidget);
    expect(find.byType(LiquidGlassLens), findsNothing);
    Navigator.of(tester.element(find.byKey(const Key('anchor')))).pop();
    await tester.pumpAndSettle();

    final einkTheme = ThemeData(
      extensions: const [
        WenkuAppearance(eink: true, oled: false, highContrast: false),
      ],
    );
    await tester.pumpWidget(_host(const SizedBox.shrink(), theme: einkTheme));
    await _openSheet<void>(
      tester,
      (_) => const SizedBox(height: 120, child: Text('墨水屏弹层')),
    );
    expect(find.text('墨水屏弹层'), findsOneWidget);
    expect(find.byType(LiquidGlassLens), findsNothing);
    Navigator.of(tester.element(find.byKey(const Key('anchor')))).pop();
    await tester.pumpAndSettle();
  });

  testWidgets('a short drag rebounds and a long drag dismisses a sheet', (
    tester,
  ) async {
    await tester.pumpWidget(_host(const SizedBox.shrink()));
    await _openSheet<void>(
      tester,
      (_) => const SizedBox(height: 200, child: Text('可拖弹层')),
    );
    await tester.drag(find.text('可拖弹层'), const Offset(0, 20));
    await tester.pumpAndSettle();
    expect(find.text('可拖弹层'), findsOneWidget);

    await tester.drag(find.text('可拖弹层'), const Offset(0, 320));
    await tester.pumpAndSettle();
    expect(find.text('可拖弹层'), findsNothing);
  });

  testWidgets('menu items expose selection semantics', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(_host(const SizedBox.shrink()));
    await _openMenu<void>(
      tester,
      (context) => SizedBox(
        height: 120,
        child: Column(
          children: [
            GlassMenuItem(label: '当前', selected: true, onPressed: () {}),
            GlassMenuItem(label: '其他', onPressed: () {}),
          ],
        ),
      ),
    );
    expect(
      tester.getSemantics(find.text('当前')),
      isSemantics(isSelected: true, label: '当前'),
    );
    expect(
      tester.getSemantics(find.text('其他')),
      isSemantics(isSelected: false, label: '其他'),
    );
    semantics.dispose();
  });

  testWidgets('desktop keyboard activates and traverses menu items', (
    tester,
  ) async {
    final presses = <String>[];
    await tester.pumpWidget(_host(const SizedBox.shrink()));
    await _openMenu<void>(
      tester,
      (context) => SizedBox(
        height: 160,
        child: Column(
          children: [
            GlassMenuItem(
              label: '首页',
              order: 0,
              autofocus: true,
              onPressed: () => presses.add('first'),
            ),
            GlassMenuItem(
              label: '设置',
              order: 1,
              onPressed: () => presses.add('second'),
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(presses, ['first']);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(presses, ['first', 'second']);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(presses, ['first', 'second', 'first']);
  });

  testWidgets('a disabled menu item is dimmed, unfocusable and inert', (
    tester,
  ) async {
    var pressed = 0;
    await tester.pumpWidget(_host(const SizedBox.shrink()));
    await _openMenu<void>(
      tester,
      (context) => SizedBox(
        height: 120,
        child: GlassMenuItem(
          label: '清空历史',
          enabled: false,
          autofocus: true,
          onPressed: () => pressed++,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final opacity = tester.widget<Opacity>(
      find.ancestor(of: find.text('清空历史'), matching: find.byType(Opacity)),
    );
    expect(opacity.opacity, lessThan(1));
    await tester.tap(find.text('清空历史'));
    await tester.pump();
    expect(pressed, 0);
  });
}
