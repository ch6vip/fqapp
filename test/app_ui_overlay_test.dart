import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/pages/search_page.dart';
import 'package:fqapp/pages/settings_category_page.dart';
import 'package:fqapp/services/app_style_tokens.dart';
import 'package:fqapp/services/app_theme_style.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/widgets/desktop_settings_body.dart';
import 'package:fqapp/widgets/home/home_back_button.dart';
import 'package:fqapp/widgets/reader/reader_theme.dart';
import 'package:fqapp/widgets/settings/settings_archive_page.dart';
import 'package:fqapp/widgets/settings/settings_widgets.dart';
import 'package:fqapp/widgets/wenku/wenku_ui.dart';

import 'support/app_ui_host.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    resetAppUiTestDiagnostics();
  });

  testWidgets(
    'an open sheet follows the live style, keeps its State and reader paper',
    (tester) async {
      final store = AppThemeStyleStore();
      addTearDown(store.dispose);
      late BuildContext pageContext;
      var initializations = 0;
      var disposals = 0;

      await tester.pumpWidget(
        AppUiHost(
          store: store,
          home: Builder(
            builder: (context) {
              pageContext = context;
              return Scaffold(
                body: Center(
                  child: TextButton(
                    key: const ValueKey('open-sheet'),
                    onPressed: () {
                      unawaited(
                        showJellySheet<String>(
                          context: context,
                          // Mirrors the reader panels: the overlay re-provides
                          // the local reading paper theme.
                          surfaceWrapper: (child) => Theme(
                            data: ReaderThemePreset.parchment.theme(
                              Theme.of(pageContext),
                            ),
                            child: child,
                          ),
                          builder: (_) => _OverlayProbe(
                            onInit: () => initializations++,
                            onDispose: () => disposals++,
                          ),
                        ),
                      );
                    },
                    child: const Text('打开'),
                  ),
                ),
              );
            },
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('open-sheet')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      final probe = find.byType(_OverlayProbe);
      expect(probe, findsOneWidget);
      expect(find.text('probe:archive'), findsOneWidget);
      expect(initializations, 1);
      final route = ModalRoute.of(tester.element(probe));
      expect(
        Theme.of(
          tester.element(find.text('probe:archive')),
        ).scaffoldBackgroundColor,
        ReaderThemePreset.parchment.backgroundColor,
      );

      await tester.enterText(
        find.byKey(const ValueKey('probe-field')),
        '未提交的输入',
      );
      await tester.pump();

      await store.select(AppThemeStyle.classic);
      await tester.pumpAndSettle();

      // Same route, same content State, live discrete tokens inside the
      // captured reading paper.
      expect(
        ModalRoute.of(tester.element(find.byType(_OverlayProbe))),
        same(route),
      );
      expect(find.text('probe:classic'), findsOneWidget);
      expect(initializations, 1);
      expect(disposals, 0);
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('probe-field')),
      );
      expect(field.controller!.text, '未提交的输入');
      final paper = Theme.of(tester.element(find.text('probe:classic')));
      expect(
        paper.scaffoldBackgroundColor,
        ReaderThemePreset.parchment.backgroundColor,
      );
      expect(
        AppStyleTokens.of(tester.element(find.text('probe:classic'))).style,
        AppThemeStyle.classic,
      );

      // Switching back is the same contract in the other direction.
      await store.select(AppThemeStyle.archive);
      await tester.pumpAndSettle();
      expect(
        ModalRoute.of(tester.element(find.byType(_OverlayProbe))),
        same(route),
      );
      expect(find.text('probe:archive'), findsOneWidget);
      expect(initializations, 1);
      expect(disposals, 0);

      await tester.tap(find.byKey(const ValueKey('probe-close')));
      await tester.pumpAndSettle();
      expect(find.byType(_OverlayProbe), findsNothing);
      expect(disposals, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('an open menu follows the live style and keeps its trigger', (
    tester,
  ) async {
    final store = AppThemeStyleStore();
    addTearDown(store.dispose);
    late BuildContext context;

    await tester.pumpWidget(
      AppUiHost(
        store: store,
        home: Scaffold(
          body: Center(
            child: GlassMenuAnchor(
              child: Builder(
                builder: (value) {
                  context = value;
                  return const SizedBox(
                    key: Key('menu-anchor'),
                    width: 80,
                    height: 40,
                    child: Text('触发'),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final result = showGlassMenu<String>(
      context: context,
      builder: (menu) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GlassMenuItem(
            label: '一',
            order: 0,
            onPressed: () => Navigator.pop(menu, 'one'),
          ),
          GlassMenuItem(
            label: '二',
            order: 1,
            onPressed: () => Navigator.pop(menu, 'two'),
          ),
        ],
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    final route = ModalRoute.of(tester.element(find.text('一')));
    expect(find.byType(GlassMenuStretch), findsOneWidget);
    expect(_anchorOpacity(tester), 0);

    await store.select(AppThemeStyle.classic);
    await tester.pumpAndSettle();

    // Same route; the archive morph and hidden trigger are gone, and the menu
    // is an ordinary Material popup.
    expect(ModalRoute.of(tester.element(find.text('一'))), same(route));
    expect(find.byType(GlassMenuStretch), findsNothing);
    expect(find.byType(GlassMenuContents), findsNothing);
    expect(_anchorOpacity(tester), 1);
    expect(
      find.ancestor(of: find.text('二'), matching: find.byType(InkWell)),
      findsOneWidget,
    );

    await tester.tap(find.text('二'));
    await tester.pumpAndSettle();
    expect(await result, 'two');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a menu outside tap still cancels in the classic style', (
    tester,
  ) async {
    final store = AppThemeStyleStore()..value = AppThemeStyle.classic;
    addTearDown(store.dispose);
    late BuildContext context;

    await tester.pumpWidget(
      AppUiHost(
        store: store,
        home: Scaffold(
          body: Center(
            child: Builder(
              builder: (value) {
                context = value;
                return const SizedBox(
                  key: Key('menu-anchor'),
                  width: 80,
                  height: 40,
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final result = showGlassMenu<String>(
      context: context,
      builder: (menu) => GlassMenuItem(
        label: '唯一',
        onPressed: () => Navigator.pop(menu, 'picked'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('唯一'), findsOneWidget);

    await tester.tapAt(const Offset(6, 6));
    await tester.pumpAndSettle();
    expect(await result, isNull);
    expect(find.text('唯一'), findsNothing);
  });

  testWidgets('classic confirmation is a Material dialog in the same route', (
    tester,
  ) async {
    final store = AppThemeStyleStore()..value = AppThemeStyle.classic;
    addTearDown(store.dispose);
    late BuildContext context;

    await tester.pumpWidget(
      AppUiHost(
        store: store,
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
    await tester.pumpAndSettle();

    Future<bool> open() => confirmArchiveAction(
      context,
      title: '删除记录',
      message: '删除后不可恢复。',
      confirmLabel: '删除',
      confirmKey: const Key('confirm'),
      cancelKey: const Key('cancel'),
    );

    var future = open();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(GlassOverlaySurface), findsNothing);
    expect(find.byKey(const ValueKey('archive-confirm')), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirm')));
    await tester.pumpAndSettle();
    expect(await future, isTrue);

    future = open();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byKey(const Key('cancel')));
    await tester.pumpAndSettle();
    expect(await future, isFalse);

    future = open();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tapAt(const Offset(6, 6));
    await tester.pumpAndSettle();
    expect(await future, isFalse);

    future = open();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    final navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    navigator.maybePop();
    await tester.pumpAndSettle();
    expect(await future, isFalse);
  });

  testWidgets('switching style keeps an open confirmation and its result', (
    tester,
  ) async {
    final store = AppThemeStyleStore();
    addTearDown(store.dispose);
    late BuildContext context;

    await tester.pumpWidget(
      AppUiHost(
        store: store,
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
    await tester.pumpAndSettle();

    final future = confirmArchiveAction(
      context,
      title: '清空历史',
      message: '全部清除。',
      confirmLabel: '清空',
      confirmKey: const Key('confirm'),
      cancelKey: const Key('cancel'),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(GlassOverlaySurface), findsOneWidget);
    final route = ModalRoute.of(
      tester.element(find.byKey(const ValueKey('archive-confirm'))),
    );

    await store.select(AppThemeStyle.classic);
    await tester.pumpAndSettle();
    expect(
      ModalRoute.of(
        tester.element(find.byKey(const ValueKey('archive-confirm'))),
      ),
      same(route),
    );
    expect(find.byType(GlassOverlaySurface), findsNothing);
    await tester.tap(find.byKey(const Key('confirm')));
    await tester.pumpAndSettle();
    expect(await future, isTrue);
  });

  testWidgets('AppFeaturePage swaps shell for the live style', (tester) async {
    final store = AppThemeStyleStore();
    addTearDown(store.dispose);
    late BuildContext context;

    await tester.pumpWidget(
      AppUiHost(
        store: store,
        home: Builder(
          builder: (value) {
            context = value;
            return Scaffold(
              body: Center(
                child: TextButton(
                  key: const ValueKey('open-page'),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => const AppFeaturePage(
                        title: '标题',
                        code: 'SYSTEM / TEST',
                        child: Text('正文'),
                      ),
                    ),
                  ),
                  child: const Text('打开'),
                ),
              ),
            );
          },
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open-page')));
    await tester.pumpAndSettle();

    expect(find.byType(WenkuPage), findsOneWidget);
    expect(find.byType(ArchiveHeaderBar), findsOneWidget);
    expect(find.text('正文'), findsOneWidget);

    await store.select(AppThemeStyle.classic);
    await tester.pumpAndSettle();
    expect(find.byType(WenkuPage), findsNothing);
    expect(find.byType(SettingsScaffold), findsOneWidget);
    expect(find.byType(HomeBackButton), findsOneWidget);
    expect(find.text('正文'), findsOneWidget);
    expect(find.text('标题'), findsOneWidget);

    await tester.tap(find.byType(HomeBackButton));
    await tester.pumpAndSettle();
    expect(find.text('正文'), findsNothing);
    expect(find.byKey(const ValueKey('open-page')), findsOneWidget);
  });

  testWidgets('a single nested settings route keeps its page in both shells', (
    tester,
  ) async {
    final store = AppThemeStyleStore();
    addTearDown(store.dispose);
    final nestedKey = GlobalKey<NavigatorState>();

    await tester.pumpWidget(
      AppUiHost(
        store: store,
        home: Navigator(
          key: nestedKey,
          onGenerateRoute: (_) => MaterialPageRoute<void>(
            builder: (_) => const SettingsArchivePage(
              title: '外观',
              code: 'SYSTEM / APPEARANCE',
              child: Text('设置正文'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Archive: no back affordance because the Navigator holds one route.
    expect(find.byType(WenkuPage), findsOneWidget);
    expect(find.byType(GlassIconButton), findsNothing);
    expect(nestedKey.currentState!.canPop(), isFalse);
    expect(await nestedKey.currentState!.maybePop(), isFalse);
    await tester.pumpAndSettle();
    expect(find.text('设置正文'), findsOneWidget);

    await store.select(AppThemeStyle.classic);
    await tester.pumpAndSettle();

    // Classic: same check, so the only route is not popped blank.
    expect(find.byType(SettingsScaffold), findsOneWidget);
    expect(find.byType(HomeBackButton), findsNothing);
    expect(nestedKey.currentState!.canPop(), isFalse);
    expect(await nestedKey.currentState!.maybePop(), isFalse);
    await tester.pumpAndSettle();
    expect(find.text('设置正文'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop settings keeps its category across a style switch', (
    tester,
  ) async {
    final store = AppThemeStyleStore();
    addTearDown(store.dispose);
    final categories = [
      SettingsCategory(
        icon: LucideIcons.palette,
        title: '外观',
        subtitle: '外观说明',
        pageBuilder: (_) => const SettingsArchivePage(
          title: '外观',
          code: 'SYSTEM / APPEARANCE',
          child: Text('外观正文'),
        ),
      ),
      SettingsCategory(
        icon: LucideIcons.book,
        title: '阅读',
        subtitle: '阅读说明',
        pageBuilder: (_) => const SettingsArchivePage(
          title: '阅读',
          code: 'SYSTEM / READING',
          child: Text('阅读正文'),
        ),
      ),
    ];

    await tester.pumpWidget(
      AppUiHost(
        store: store,
        home: Scaffold(body: DesktopSettingsBody(categories: categories)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('外观正文'), findsOneWidget);

    await tester.tap(find.text('阅读'));
    await tester.pumpAndSettle();
    expect(find.text('阅读正文'), findsOneWidget);
    final nested = tester.state<NavigatorState>(
      find.descendant(
        of: find.byType(DesktopSettingsBody),
        matching: find.byType(Navigator),
      ),
    );

    await store.select(AppThemeStyle.classic);
    await tester.pumpAndSettle();

    expect(
      nested,
      same(
        tester.state<NavigatorState>(
          find.descendant(
            of: find.byType(DesktopSettingsBody),
            matching: find.byType(Navigator),
          ),
        ),
      ),
    );
    expect(nested.canPop(), isFalse);
    expect(find.text('阅读正文'), findsOneWidget);
    expect(find.byType(SettingsScaffold), findsOneWidget);
    expect(find.byType(HomeBackButton), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('SearchRoute uses the archive plane and the classic platform '
      'transition, keeping settings and results', (tester) async {
    final store = AppThemeStyleStore();
    addTearDown(store.dispose);
    final navigatorKey = GlobalKey<NavigatorState>();
    late BuildContext context;

    await tester.pumpWidget(
      AppUiHost(
        store: store,
        navigatorKey: navigatorKey,
        home: Builder(
          builder: (value) {
            context = value;
            return const Scaffold(body: Text('首页'));
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    final archiveResult = navigatorKey.currentState!.push<String>(
      SearchRoute.open<String>(
        context,
        builder: (_) => const Scaffold(body: Text('搜索页')),
        settings: const RouteSettings(name: 'search-test'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(find.byType(ArchivePlaneTransition), findsOneWidget);
    final archiveRoute = ModalRoute.of(tester.element(find.text('搜索页')));
    expect(archiveRoute!.settings.name, 'search-test');
    expect(archiveRoute.transitionDuration, WenkuMotion.enter);
    await tester.pumpAndSettle();
    navigatorKey.currentState!.pop('archive-done');
    await tester.pumpAndSettle();
    expect(await archiveResult, 'archive-done');

    await store.select(AppThemeStyle.classic);
    await tester.pumpAndSettle();

    final classicResult = navigatorKey.currentState!.push<String>(
      SearchRoute.open<String>(
        context,
        builder: (_) => const Scaffold(body: Text('经典搜索页')),
        settings: const RouteSettings(name: 'classic-search-test'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(ArchivePlaneTransition), findsNothing);
    final classicRoute = ModalRoute.of(tester.element(find.text('经典搜索页')));
    expect(classicRoute, isA<SearchRoute<String>>());
    expect(classicRoute!.settings.name, 'classic-search-test');
    final theme = Theme.of(tester.element(find.text('经典搜索页')));
    final builder =
        theme.pageTransitionsTheme.builders[theme.platform] ??
        const ZoomPageTransitionsBuilder();
    expect(classicRoute.transitionDuration, builder.transitionDuration);
    await tester.pumpAndSettle();
    navigatorKey.currentState!.pop('classic-done');
    await tester.pumpAndSettle();
    expect(await classicResult, 'classic-done');
    expect(tester.takeException(), isNull);
  });
}

double _anchorOpacity(WidgetTester tester) => tester
    .widget<Opacity>(
      find
          .descendant(
            of: find.byType(GlassMenuAnchor),
            matching: find.byType(Opacity),
          )
          .first,
    )
    .opacity;

/// Stateful sheet content: proves the caller's State (and its input) survives a
/// classic/archive switch instead of being re-inflated with the new shell.
class _OverlayProbe extends StatefulWidget {
  const _OverlayProbe({required this.onInit, required this.onDispose});

  final VoidCallback onInit;
  final VoidCallback onDispose;

  @override
  State<_OverlayProbe> createState() => _OverlayProbeState();
}

class _OverlayProbeState extends State<_OverlayProbe> {
  final _controller = TextEditingController(text: '初始');

  @override
  void initState() {
    super.initState();
    widget.onInit();
  }

  @override
  void dispose() {
    _controller.dispose();
    widget.onDispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(24),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('probe:${AppStyleTokens.of(context).style.name}'),
        TextField(key: const ValueKey('probe-field'), controller: _controller),
        TextButton(
          key: const ValueKey('probe-close'),
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}
