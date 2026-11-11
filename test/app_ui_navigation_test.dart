import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/main.dart';
import 'package:fqapp/models/homepage_page.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/home_page.dart';
import 'package:fqapp/pages/home_provider.dart';
import 'package:fqapp/pages/library_page.dart';
import 'package:fqapp/pages/mine_page.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/pages/settings_page.dart';
import 'package:fqapp/pages/text_replacement_page.dart';
import 'package:fqapp/pages/theme_page.dart';
import 'package:fqapp/services/app_theme_style.dart';
import 'package:fqapp/services/desktop_platform.dart';
import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/services/shelf_group_store.dart';
import 'package:fqapp/services/shelf_store.dart';
import 'package:fqapp/services/shelf_view_store.dart';
import 'package:fqapp/widgets/app_ui/app_ui_scope.dart';
import 'package:fqapp/widgets/classic_shell_dock.dart';
import 'package:fqapp/widgets/desktop_app_frame.dart';
import 'package:fqapp/widgets/desktop_settings_body.dart';
import 'package:fqapp/widgets/settings/settings_widgets.dart';
import 'package:fqapp/widgets/shell_dock.dart';

import 'support/app_ui_host.dart';
import 'support/fakes.dart';

/// 移动端壳层的页面容器是 Stack + Offstage：当前 tab 是唯一 offstage=false
/// 的页（替代原 LazyIndexedStack.index / PageController.page）。
int rootTab(WidgetTester tester, {bool skipOffstage = true}) {
  for (var i = 0; i < 4; i++) {
    final finder = find.byKey(
      ValueKey('root-tab-offstage-$i'),
      skipOffstage: skipOffstage,
    );
    if (finder.evaluate().isEmpty) continue;
    if (!tester.widget<Offstage>(finder).offstage) return i;
  }
  fail('no visible root tab found');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory hiveDirectory;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    // Isolated, empty local data. Boxes are opened outside the widget test's
    // fake-async zone so the injected AppBootstrap initializer can finish.
    hiveDirectory = await Directory.systemTemp.createTemp('fqapp-ui-nav-');
    Hive.init(hiveDirectory.path);
    await LibraryStore.instance.init();
    await ShelfStore.instance.init();
    await ShelfGroupStore.instance.init();
    await ShelfViewStore.instance.load();
  });

  tearDown(() async {
    await Hive.close();
    if (hiveDirectory.existsSync()) {
      await hiveDirectory.delete(recursive: true);
    }
  });

  testWidgets('real shell, tabs and reader keep state across style switches', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    setSingleChapterPrefs({'reader_page_mode': 'scroll'});

    final store = AppThemeStyleStore();
    addTearDown(store.dispose);
    final backendStarts = <int>[];
    Future<void> backend() async => backendStarts.add(backendStarts.length + 1);

    resetAppUiTestDiagnostics();
    await tester.pumpWidget(
      _withFakeHome(
        FqApp(
          initializer: _isolatedStartup,
          backendStarter: backend,
          styleStore: store,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(RootShell), findsOneWidget);
    expect(find.byKey(const ValueKey('root-page-stack')), findsOneWidget);
    expect(backendStarts, isNotEmpty);
    expect(find.byType(HomePage), findsOneWidget);

    final rootShellState = tester.state(find.byType(RootShell));
    final stackElement = tester.element(
      find.byKey(const ValueKey('root-page-stack')),
    );
    final homeState = tester.state(find.byType(HomePage));
    final rootNavigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );

    Finder dockLabel(String label) =>
        find.descendant(of: find.byType(ShellDock), matching: find.text(label));

    await tester.tap(dockLabel('书架'));
    await tester.pumpAndSettle();
    expect(find.byType(LibraryPage), findsOneWidget);
    final libraryState = tester.state(find.byType(LibraryPage));

    await tester.tap(dockLabel('我的'));
    await tester.pumpAndSettle();
    expect(find.byType(MinePage), findsOneWidget);
    final mineState = tester.state(find.byType(MinePage));
    final currentTab = rootTab(tester);
    expect(currentTab, 3);

    final chapterLoads = <String>[];
    Future<String> loadChapter(Chapter chapter) async {
      chapterLoads.add(chapter.itemId);
      return '${chapter.title}\n这是 ${chapter.title} 的正文。';
    }

    unawaited(
      rootNavigator.push(
        MaterialPageRoute<void>(
          builder: (_) => ReaderPage(
            bookId: 'scope-book',
            title: '范围测试',
            chapters: _chapters,
            startIndex: 0,
            chapterLoader: loadChapter,
            readerStore: MemoryReaderStore(),
            chapterCache: MemoryChapterCache(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ReaderPage), findsOneWidget);
    expect(find.textContaining('这是 第一章 的正文。'), findsOneWidget);
    final readerState = tester.state(find.byType(ReaderPage));
    final readerRoute = ModalRoute.of(tester.element(find.byType(ReaderPage)));
    final loadsBeforeSwitch = List<String>.of(chapterLoads);
    expect(loadsBeforeSwitch, isNotEmpty);

    void expectOwnersKept(AppThemeStyle expected, String label) {
      // The reader route is opaque, so the shell below it is offstage.
      expect(
        tester.state(find.byType(RootShell, skipOffstage: false)),
        same(rootShellState),
        reason: label,
      );
      expect(
        tester.element(
          find.byKey(const ValueKey('root-page-stack'), skipOffstage: false),
        ),
        same(stackElement),
        reason: label,
      );
      expect(
        tester.state(find.byType(HomePage, skipOffstage: false)),
        same(homeState),
        reason: label,
      );
      expect(
        tester.state(find.byType(LibraryPage, skipOffstage: false)),
        same(libraryState),
        reason: label,
      );
      expect(
        tester.state(find.byType(MinePage, skipOffstage: false)),
        same(mineState),
        reason: label,
      );
      expect(rootTab(tester, skipOffstage: false), currentTab, reason: label);
      expect(
        tester.state<NavigatorState>(find.byType(Navigator).first),
        same(rootNavigator),
        reason: label,
      );
      expect(find.byType(ReaderPage), findsOneWidget, reason: label);
      expect(
        tester.state(find.byType(ReaderPage, skipOffstage: false)),
        same(readerState),
        reason: label,
      );
      expect(
        ModalRoute.of(
          tester.element(find.byType(ReaderPage, skipOffstage: false)),
        ),
        same(readerRoute),
        reason: label,
      );
      expect(chapterLoads, loadsBeforeSwitch, reason: label);
      expect(find.byType(AppUiScope), findsOneWidget, reason: label);

      // Real contexts: the shell, both visited tabs, the home tab and the
      // reader route all see the same injected scope and discrete style.
      final contexts = <String, BuildContext>{
        'RootShell': tester.element(
          find.byType(RootShell, skipOffstage: false),
        ),
        'root stack': tester.element(
          find.byKey(const ValueKey('root-page-stack'), skipOffstage: false),
        ),
        'HomePage tab': tester.element(
          find.byType(HomePage, skipOffstage: false),
        ),
        'LibraryPage tab': tester.element(
          find.byType(LibraryPage, skipOffstage: false),
        ),
        'MinePage tab': tester.element(
          find.byType(MinePage, skipOffstage: false),
        ),
        'ReaderPage': tester.element(find.byType(ReaderPage)),
      };
      for (final entry in contexts.entries) {
        _expectLiveScope(entry.value, expected, store, '$label ${entry.key}');
      }
    }

    expectOwnersKept(AppThemeStyle.archive, 'archive before switching');
    await _switchStyle(tester, store, AppThemeStyle.classic);
    expect(find.byType(ClassicShellDock, skipOffstage: false), findsOneWidget);
    expectOwnersKept(AppThemeStyle.classic, 'classic');

    await _switchStyle(tester, store, AppThemeStyle.archive);
    expectOwnersKept(AppThemeStyle.archive, 'archive again');

    rootNavigator.pop();
    await tester.pumpAndSettle();
    expect(find.byType(ReaderPage), findsNothing);
    expect(find.byType(MinePage), findsOneWidget);
    expect(rootTab(tester), currentTab);
    expect(
      tester.state<NavigatorState>(find.byType(Navigator).first),
      same(rootNavigator),
    );
    expect(tester.state(find.byType(MinePage)), same(mineState));
    _expectLiveScope(
      tester.element(find.byType(MinePage)),
      AppThemeStyle.archive,
      store,
      'tabs after returning',
    );
    // Every live-style read in this scenario went through the scope.
    expect(AppUiScope.debugFallbackReads, 0);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('windows settings nested stack survives style switches', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      desktopTab.value = 0;
      DesktopPlatform.fullscreen.value = false;
      addTearDown(() {
        desktopTab.value = 0;
        DesktopPlatform.fullscreen.value = false;
      });

      final store = AppThemeStyleStore();
      addTearDown(store.dispose);
      resetAppUiTestDiagnostics();
      await tester.pumpWidget(
        _withFakeHome(
          FqApp(
            initializer: _isolatedStartup,
            backendStarter: () async {},
            styleStore: store,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(DesktopAppFrame), findsOneWidget);
      final rootNavigator = DesktopPlatform.navigatorKey.currentState;
      expect(rootNavigator, isNotNull);

      await tester.tap(find.byKey(const Key('desktop-settings')));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsPage), findsOneWidget);
      expect(find.byType(DesktopSettingsBody), findsOneWidget);
      final settingsBodyState = tester.state(find.byType(DesktopSettingsBody));

      // Select a non-default category; the two-pane body rebuilds its nested
      // Navigator with that category's page.
      final themeRow = find.descendant(
        of: find.byType(DesktopSettingsBody),
        matching: find.widgetWithText(SettingsRow, '主题'),
      );
      expect(themeRow, findsOneWidget);
      await tester.tap(themeRow);
      await tester.pumpAndSettle();
      expect(find.byType(ThemePage), findsOneWidget);
      final themePageState = tester.state(find.byType(ThemePage));

      final nestedFinder = find.descendant(
        of: find.byType(DesktopSettingsBody),
        matching: find.byType(Navigator),
      );
      expect(nestedFinder, findsOneWidget);
      final nestedNavigator = tester.state<NavigatorState>(nestedFinder);

      // A real settings subpage pushed on the nested Navigator.
      unawaited(
        nestedNavigator.push(
          MaterialPageRoute<void>(builder: (_) => const TextReplacementPage()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(TextReplacementPage), findsOneWidget);
      final replacementState = tester.state(find.byType(TextReplacementPage));
      expect(nestedNavigator.canPop(), isTrue);

      Finder selectedThemeCheck() => find.descendant(
        of: find.widgetWithText(SettingsRow, '主题'),
        matching: find.byIcon(LucideIcons.check),
      );

      void expectDesktopKeepers(AppThemeStyle expected, String label) {
        expect(
          tester.state(find.byType(DesktopSettingsBody)),
          same(settingsBodyState),
          reason: label,
        );
        expect(
          tester.state<NavigatorState>(
            find.descendant(
              of: find.byType(DesktopSettingsBody),
              matching: find.byType(Navigator),
            ),
          ),
          same(nestedNavigator),
          reason: label,
        );
        expect(
          tester.state(find.byType(TextReplacementPage)),
          same(replacementState),
          reason: label,
        );
        expect(nestedNavigator.canPop(), isTrue, reason: label);
        expect(selectedThemeCheck(), findsOneWidget, reason: label);
        expect(
          DesktopPlatform.navigatorKey.currentState,
          same(rootNavigator),
          reason: label,
        );

        // Real desktop contexts: the frame, the two-pane settings body, its
        // nested Navigator, the pushed subpage and the selected category row.
        final contexts = <String, BuildContext>{
          'DesktopAppFrame': tester.element(find.byType(DesktopAppFrame)),
          'SettingsPage': tester.element(find.byType(SettingsPage)),
          'DesktopSettingsBody': tester.element(
            find.byType(DesktopSettingsBody),
          ),
          'nested Navigator': tester.element(nestedFinder),
          'TextReplacementPage': tester.element(
            find.byType(TextReplacementPage),
          ),
          '主题 row': tester.element(find.widgetWithText(SettingsRow, '主题')),
        };
        for (final entry in contexts.entries) {
          _expectLiveScope(entry.value, expected, store, '$label ${entry.key}');
        }
      }

      expectDesktopKeepers(AppThemeStyle.archive, 'archive before switching');
      await _switchStyle(tester, store, AppThemeStyle.classic);
      expectDesktopKeepers(AppThemeStyle.classic, 'classic');
      await _switchStyle(tester, store, AppThemeStyle.archive);
      expectDesktopKeepers(AppThemeStyle.archive, 'archive again');

      // Back out of the subpage: the category route and its State remain.
      nestedNavigator.pop();
      await tester.pumpAndSettle();
      expect(find.byType(TextReplacementPage), findsNothing);
      expect(find.byType(ThemePage), findsOneWidget);
      expect(tester.state(find.byType(ThemePage)), same(themePageState));
      expect(nestedNavigator.canPop(), isFalse);
      expect(selectedThemeCheck(), findsOneWidget);

      // Back out of settings: the desktop frame and its navigator stay.
      rootNavigator!.pop();
      await tester.pumpAndSettle();
      expect(find.byType(SettingsPage), findsNothing);
      expect(find.byType(DesktopAppFrame), findsOneWidget);
      expect(DesktopPlatform.navigatorKey.currentState, same(rootNavigator));
      _expectLiveScope(
        tester.element(find.byType(DesktopAppFrame)),
        AppThemeStyle.archive,
        store,
        'frame after returning',
      );
      expect(AppUiScope.debugFallbackReads, 0);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

void _expectLiveScope(
  BuildContext context,
  AppThemeStyle expected,
  AppThemeStyleStore store,
  String label,
) {
  final scope = AppUiScope.maybeOf(context);
  expect(scope, isNotNull, reason: '$label: scope present');
  expect(scope!.notifier, same(store), reason: '$label: injected store');
  expect(AppUiScope.of(context), expected, reason: '$label: discrete style');
  expect(
    AppUiScope.presentationOf(context).isClassic,
    expected == AppThemeStyle.classic,
    reason: '$label: presentation',
  );
}

Future<void> _isolatedStartup() async {
  await LibraryStore.instance.init();
  await ShelfStore.instance.init();
  await ShelfGroupStore.instance.init();
  await ShelfViewStore.instance.load();
}

Widget _withFakeHome(Widget child) => ProviderScope(
  overrides: [
    homeProvider.overrideWith(
      () => HomeNotifier(
        usesLocalTabs: true,
        homepageLoader:
            ({int tabType = 2, int offset = 0, String? sessionId}) async =>
                const HomepagePage(
                  items: [],
                  cells: [],
                  nextOffset: null,
                  sessionId: null,
                ),
        searchLoader: (query, {int page = 1}) async => const [],
      ),
    ),
  ],
  child: child,
);

Future<void> _switchStyle(
  WidgetTester tester,
  AppThemeStyleStore store,
  AppThemeStyle style,
) async {
  await store.select(style);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
  await tester.pumpAndSettle();
}

final _chapters = [
  Chapter(itemId: 'chapter-1', title: '第一章', volumeName: '正文'),
  Chapter(itemId: 'chapter-2', title: '第二章', volumeName: '正文'),
  Chapter(itemId: 'chapter-3', title: '尾声', volumeName: '正文'),
];
