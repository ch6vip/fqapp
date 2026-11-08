import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/pages/api_service_page.dart';
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

  testWidgets('AppFeaturePage keeps child State and focus across shells', (
    tester,
  ) async {
    final store = AppThemeStyleStore();
    addTearDown(store.dispose);
    var inits = 0;
    var disposals = 0;

    await tester.pumpWidget(
      AppUiHost(
        store: store,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                key: const ValueKey('open-feature'),
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => AppFeaturePage(
                      title: '标题',
                      code: 'SYSTEM / TEST',
                      child: _DraftProbe(
                        onInit: () => inits++,
                        onDispose: () => disposals++,
                      ),
                    ),
                  ),
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open-feature')));
    await tester.pumpAndSettle();
    final state = tester.state(find.byType(_DraftProbe));
    expect(inits, 1);
    await tester.enterText(find.byKey(const ValueKey('draft-field')), '未提交草稿');
    await tester.pump();
    expect(_draftFocus(tester).hasFocus, isTrue);

    await store.select(AppThemeStyle.classic);
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScaffold), findsOneWidget);
    expect(tester.state(find.byType(_DraftProbe)), same(state));
    expect(inits, 1);
    expect(disposals, 0);
    expect(_draftText(tester), '未提交草稿');
    expect(find.text('未提交草稿'), findsOneWidget);
    expect(_draftFocus(tester).hasFocus, isTrue);

    await store.select(AppThemeStyle.archive);
    await tester.pumpAndSettle();
    expect(find.byType(WenkuPage), findsOneWidget);
    expect(tester.state(find.byType(_DraftProbe)), same(state));
    expect(inits, 1);
    expect(disposals, 0);
    expect(_draftText(tester), '未提交草稿');
    expect(_draftFocus(tester).hasFocus, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('SettingsArchivePage keeps child State and focus across shells', (
    tester,
  ) async {
    final store = AppThemeStyleStore()..value = AppThemeStyle.classic;
    addTearDown(store.dispose);
    var inits = 0;
    var disposals = 0;

    await tester.pumpWidget(
      AppUiHost(
        store: store,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                key: const ValueKey('open-settings-page'),
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => SettingsArchivePage(
                      title: '外观',
                      code: 'SYSTEM / APPEARANCE',
                      child: _DraftProbe(
                        onInit: () => inits++,
                        onDispose: () => disposals++,
                      ),
                    ),
                  ),
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open-settings-page')));
    await tester.pumpAndSettle();
    final state = tester.state(find.byType(_DraftProbe));
    expect(inits, 1);
    expect(find.byType(SettingsScaffold), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('draft-field')), '页面草稿');
    await tester.pump();
    expect(_draftFocus(tester).hasFocus, isTrue);

    await store.select(AppThemeStyle.archive);
    await tester.pumpAndSettle();
    expect(find.byType(WenkuPage), findsOneWidget);
    expect(tester.state(find.byType(_DraftProbe)), same(state));
    expect(inits, 1);
    expect(disposals, 0);
    expect(_draftText(tester), '页面草稿');
    expect(_draftFocus(tester).hasFocus, isTrue);

    await store.select(AppThemeStyle.classic);
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScaffold), findsOneWidget);
    expect(tester.state(find.byType(_DraftProbe)), same(state));
    expect(inits, 1);
    expect(disposals, 0);
    expect(_draftText(tester), '页面草稿');
    expect(_draftFocus(tester).hasFocus, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a scrolled open menu keeps its offset and result across shells',
    (tester) async {
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
        builder: (menu) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < 40; i++)
              GlassMenuItem(
                order: i,
                label: '行 $i',
                onPressed: () => Navigator.pop(menu, 'v$i'),
              ),
          ],
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.drag(find.text('行 2'), const Offset(0, -240));
      await tester.pumpAndSettle();
      final position = tester
          .state<ScrollableState>(find.byType(Scrollable))
          .position;
      expect(position.pixels, greaterThan(200));

      await store.select(AppThemeStyle.classic);
      await tester.pumpAndSettle();
      expect(find.byType(GlassMenuStretch), findsNothing);
      final movedPosition = tester
          .state<ScrollableState>(find.byType(Scrollable))
          .position;
      // The scrollable element is reparented; the offset is what must carry
      // over (row heights differ slightly between the two surfaces).
      expect(movedPosition.pixels, closeTo(position.pixels, .01));

      await tester.tap(find.text('行 8'));
      await tester.pumpAndSettle();
      expect(await result, 'v8');

      // The reverse direction keeps it too, and cancellation still works.
      final classicFirst = showGlassMenu<String>(
        context: context,
        builder: (menu) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < 40; i++)
              GlassMenuItem(
                order: i,
                label: '行 $i',
                onPressed: () => Navigator.pop(menu, 'v$i'),
              ),
          ],
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.drag(find.text('行 2'), const Offset(0, -240));
      await tester.pumpAndSettle();
      final classicOffset = tester
          .state<ScrollableState>(find.byType(Scrollable))
          .position
          .pixels;
      expect(classicOffset, greaterThan(200));
      await store.select(AppThemeStyle.archive);
      await tester.pumpAndSettle();
      expect(
        tester.state<ScrollableState>(find.byType(Scrollable)).position.pixels,
        closeTo(classicOffset, .01),
      );
      await tester.tapAt(const Offset(6, 6));
      await tester.pumpAndSettle();
      expect(await classicFirst, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('classic confirm centers inside the keyboard safe rect', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
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

    final future = open();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    final openRect = tester.getRect(
      find.byKey(const ValueKey('archive-confirm')),
    );
    expect(openRect.bottom, lessThanOrEqualTo(600 - 24 + .5));

    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();
    final keyboardRect = tester.getRect(
      find.byKey(const ValueKey('archive-confirm')),
    );
    expect(keyboardRect.bottom, lessThanOrEqualTo(300 - 24 + .5));
    expect(keyboardRect.top, greaterThanOrEqualTo(24 - .5));
    await tester.tap(find.byKey(const Key('confirm')));
    await tester.pumpAndSettle();
    expect(await future, isTrue);

    // Opening with the keyboard already up, then hiding it, recentres.
    final second = open();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      tester.getRect(find.byKey(const ValueKey('archive-confirm'))).bottom,
      lessThanOrEqualTo(300 - 24 + .5),
    );
    tester.view.viewInsets = const FakeViewPadding();
    await tester.pumpAndSettle();
    final recentred = tester.getRect(
      find.byKey(const ValueKey('archive-confirm')),
    );
    expect(recentred.bottom, lessThanOrEqualTo(600 - 24 + .5));
    expect(recentred.bottom, greaterThan(300));
    await tester.tap(find.byKey(const Key('cancel')));
    await tester.pumpAndSettle();
    expect(await second, isFalse);
  });

  testWidgets('classic confirm respects asymmetric safe areas in a nested '
      'overlay', (tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    tester.view.padding = const FakeViewPadding(
      left: 40,
      top: 20,
      right: 10,
      bottom: 30,
    );
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.reset);
    final store = AppThemeStyleStore()..value = AppThemeStyle.classic;
    addTearDown(store.dispose);
    late BuildContext nestedContext;

    await tester.pumpWidget(
      AppUiHost(
        store: store,
        home: Center(
          child: SizedBox(
            width: 600,
            height: 480,
            child: Navigator(
              onGenerateRoute: (_) => MaterialPageRoute<void>(
                builder: (context) {
                  nestedContext = context;
                  return const Scaffold(body: Center(child: Text('嵌套页')));
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final future = confirmArchiveAction(
      nestedContext,
      title: '嵌套确认',
      message: '确认后继续。',
      confirmLabel: '继续',
      confirmKey: const Key('nested-confirm'),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    final rect = tester.getRect(find.byKey(const ValueKey('archive-confirm')));
    // Global safe rect: left 40, top 20, right 790, bottom 300.
    expect(rect.left, greaterThanOrEqualTo(40 + 24 - .5));
    expect(rect.top, greaterThanOrEqualTo(20 + 24 - .5));
    expect(rect.right, lessThanOrEqualTo(790 - 24 + .5));
    expect(rect.bottom, lessThanOrEqualTo(300 - 24 + .5));
    await tester.tap(find.byKey(const Key('nested-confirm')));
    await tester.pumpAndSettle();
    expect(await future, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('classic confirm scrolls inside a short keyboard safe rect', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 360);
    tester.view.devicePixelRatio = 1.0;
    tester.view.viewInsets = const FakeViewPadding(bottom: 180);
    addTearDown(tester.view.reset);
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

    final future = confirmArchiveAction(
      context,
      title: '删除记录',
      message: '删除后不可恢复。',
      confirmLabel: '删除',
      confirmKey: const Key('confirm'),
      cancelKey: const Key('cancel'),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.takeException(), isNull);
    final scrollable = tester.state<ScrollableState>(
      find.byType(Scrollable).first,
    );
    expect(scrollable.position.maxScrollExtent, greaterThan(0));

    scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm')));
    await tester.pumpAndSettle();
    expect(await future, isTrue);
  });

  testWidgets('classic confirm scrolls a long message at large text scale', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 700);
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = 1.8;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    addTearDown(tester.view.reset);
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

    final message = List.generate(
      40,
      (index) => '第 $index 行：这是一段很长的确认说明。',
    ).join('\n');
    final future = confirmArchiveAction(
      context,
      title: '清空历史',
      message: message,
      confirmLabel: '清空',
      confirmKey: const Key('confirm'),
      cancelKey: const Key('cancel'),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.takeException(), isNull);
    final scrollable = tester.state<ScrollableState>(
      find.byType(Scrollable).first,
    );
    expect(scrollable.position.maxScrollExtent, greaterThan(0));

    scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('cancel')));
    await tester.pumpAndSettle();
    expect(await future, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the modal scrim follows the live style and preview', (
    tester,
  ) async {
    final store = AppThemeStyleStore();
    addTearDown(store.dispose);
    final previewing = ValueNotifier<bool>(false);
    addTearDown(previewing.dispose);
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

    final result = showJellySheet<void>(
      context: context,
      previewing: previewing,
      builder: (_) => const SizedBox(height: 120, child: Text('遮罩弹层')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    final route = ModalRoute.of(tester.element(find.text('遮罩弹层')))!;
    expect(_barrierAlpha(tester), closeTo(.16, .001));
    expect(route.barrierColor, Colors.black.withValues(alpha: .16));

    await store.select(AppThemeStyle.classic);
    await tester.pumpAndSettle();
    expect(_barrierAlpha(tester), closeTo(.5, .001));
    expect(route.barrierColor, Colors.black.withValues(alpha: .5));

    await store.select(AppThemeStyle.archive);
    await tester.pumpAndSettle();
    expect(_barrierAlpha(tester), closeTo(.16, .001));
    expect(route.barrierColor, Colors.black.withValues(alpha: .16));

    previewing.value = true;
    await tester.pumpAndSettle();
    expect(find.byType(AnimatedModalBarrier), findsNothing);

    previewing.value = false;
    await tester.pumpAndSettle();
    expect(_barrierAlpha(tester), closeTo(.16, .001));

    await store.select(AppThemeStyle.classic);
    await tester.pumpAndSettle();
    expect(_barrierAlpha(tester), closeTo(.5, .001));
    expect(route.barrierColor, Colors.black.withValues(alpha: .5));

    Navigator.of(context).pop();
    await tester.pumpAndSettle();
    await result;
    expect(tester.takeException(), isNull);
  });

  testWidgets('the confirmation scrim follows the live style', (tester) async {
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
    final route = ModalRoute.of(tester.element(find.text('清空历史')))!;
    expect(_barrierAlpha(tester), closeTo(.16, .001));
    expect(route.barrierColor, Colors.black.withValues(alpha: .16));

    await store.select(AppThemeStyle.classic);
    await tester.pumpAndSettle();
    expect(_barrierAlpha(tester), closeTo(.5, .001));
    expect(route.barrierColor, Colors.black.withValues(alpha: .5));

    await store.select(AppThemeStyle.archive);
    await tester.pumpAndSettle();
    expect(_barrierAlpha(tester), closeTo(.16, .001));
    expect(route.barrierColor, Colors.black.withValues(alpha: .16));

    await tester.tap(find.byKey(const Key('cancel')));
    await tester.pumpAndSettle();
    expect(await future, isFalse);
  });

  testWidgets('classic preview only makes the surface transparent', (
    tester,
  ) async {
    final store = AppThemeStyleStore()..value = AppThemeStyle.classic;
    addTearDown(store.dispose);
    final previewing = ValueNotifier<bool>(false);
    addTearDown(previewing.dispose);
    var taps = 0;
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

    final result = showJellySheet<void>(
      context: context,
      previewing: previewing,
      builder: (_) => _PreviewProbe(onTap: () => taps++),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(_sheetCardMaterial(tester).color, isNot(Colors.transparent));
    expect(find.text('preview:classic'), findsOneWidget);

    previewing.value = true;
    await tester.pumpAndSettle();
    expect(_sheetCardMaterial(tester).color, Colors.transparent);
    expect(find.text('preview:classic'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('preview-tap')));
    await tester.pump();
    expect(taps, 1);

    await store.select(AppThemeStyle.archive);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<GlassOverlaySurface>(find.byType(GlassOverlaySurface))
          .transparent,
      isTrue,
    );
    expect(find.text('preview:archive'), findsOneWidget);

    previewing.value = false;
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<GlassOverlaySurface>(find.byType(GlassOverlaySurface))
          .transparent,
      isFalse,
    );

    await store.select(AppThemeStyle.classic);
    await tester.pumpAndSettle();
    expect(_sheetCardMaterial(tester).color, isNot(Colors.transparent));
    Navigator.of(context).pop();
    await tester.pumpAndSettle();
    await result;
    expect(tester.takeException(), isNull);
  });

  testWidgets('classic preview keeps guarded drag semantics', (tester) async {
    final store = AppThemeStyleStore()..value = AppThemeStyle.classic;
    addTearDown(store.dispose);
    final previewing = ValueNotifier<bool>(true);
    addTearDown(previewing.dispose);
    final canPop = ValueNotifier<bool>(false);
    addTearDown(canPop.dispose);
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

    final result = showJellySheet<void>(
      context: context,
      previewing: previewing,
      guardDragDismiss: true,
      builder: (_) => ValueListenableBuilder<bool>(
        valueListenable: canPop,
        builder: (context, allowed, _) => PopScope(
          canPop: allowed,
          child: const SizedBox(
            height: 200,
            child: Center(child: Text('受保护面板')),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    await tester.drag(find.text('受保护面板'), const Offset(0, 320));
    await tester.pumpAndSettle();
    expect(find.text('受保护面板'), findsOneWidget);

    canPop.value = true;
    await tester.pump();
    await tester.drag(find.text('受保护面板'), const Offset(0, 320));
    await tester.pumpAndSettle();
    expect(find.text('受保护面板'), findsNothing);
    await result;
    expect(tester.takeException(), isNull);
  });

  testWidgets('classic API page does not reserve the archive header twice', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final store = AppThemeStyleStore()..value = AppThemeStyle.classic;
    addTearDown(store.dispose);

    await tester.pumpWidget(
      AppUiHost(store: store, home: const ApiServicePage()),
    );
    await tester.pumpAndSettle();

    expect(find.byType(SettingsScaffold), findsOneWidget);
    expect(find.byType(WenkuPage), findsNothing);
    // Classic body: Material switch and the pre-#291 settings cards, not the
    // archive ContentPanel/AppGlassSwitch vocabulary.
    expect(find.byType(SettingsGroupCard), findsWidgets);
    expect(find.byType(AppGlassSwitch), findsNothing);
    expect(find.byType(Switch), findsWidgets);
    // The classic feature shell paints its opaque AppBar over the body, so the
    // first row must start just below it (single header clearance, not the
    // archive masthead height twice).
    final appBarBottom = tester.getBottomLeft(find.byType(AppBar)).dy;
    final dot = tester
        .getTopLeft(find.byKey(const ValueKey('api-status-dot')))
        .dy;
    expect(dot, greaterThan(appBarBottom));
    expect(dot - appBarBottom, lessThan(60));

    await store.select(AppThemeStyle.archive);
    await tester.pumpAndSettle();
    expect(find.byType(WenkuPage), findsOneWidget);
    final archivePanel = tester.getTopLeft(find.byType(ContentPanel).first).dy;
    expect(archivePanel, closeTo(76, 2));
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

String _draftText(WidgetTester tester) => tester
    .widget<TextField>(find.byKey(const ValueKey('draft-field')))
    .controller!
    .text;

FocusNode _draftFocus(WidgetTester tester) => tester
    .widget<TextField>(find.byKey(const ValueKey('draft-field')))
    .focusNode!;

double _barrierAlpha(WidgetTester tester) => tester
    .widget<AnimatedModalBarrier>(find.byType(AnimatedModalBarrier))
    .color
    .value!
    .a;

Material _sheetCardMaterial(WidgetTester tester) =>
    tester.widgetList<Material>(find.byType(Material)).firstWhere((material) {
      final shape = material.shape;
      return shape is RoundedRectangleBorder &&
          shape.borderRadius ==
              const BorderRadius.vertical(top: Radius.circular(16));
    });

/// Stateful page content: proves a shell switch keeps the same Element/State
/// (draft and focus included) instead of re-inflating it.
class _DraftProbe extends StatefulWidget {
  const _DraftProbe({required this.onInit, required this.onDispose});

  final VoidCallback onInit;
  final VoidCallback onDispose;

  @override
  State<_DraftProbe> createState() => _DraftProbeState();
}

class _DraftProbeState extends State<_DraftProbe> {
  final _controller = TextEditingController(text: '初始');
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    widget.onInit();
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    widget.onDispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: TextField(
      key: const ValueKey('draft-field'),
      controller: _controller,
      focusNode: _focus,
    ),
  );
}

/// Sheet foreground for preview checks: its action must stay visible and
/// tappable while only the panel material is transparent.
class _PreviewProbe extends StatelessWidget {
  const _PreviewProbe({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(20),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('preview:${AppStyleTokens.of(context).style.name}'),
        TextButton(
          key: const ValueKey('preview-tap'),
          onPressed: onTap,
          child: const Text('预览动作'),
        ),
      ],
    ),
  );
}
