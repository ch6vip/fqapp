import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/pages/mine_page.dart';
import 'package:fqapp/pages/settings_page.dart';
import 'package:fqapp/pages/theme_page.dart';
import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/services/app_theme_style.dart';
import 'package:fqapp/services/book_open_preferences.dart';
import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/widgets/classic_shell_dock.dart';
import 'package:fqapp/widgets/mine/classic_mine_entries.dart';
import 'package:fqapp/widgets/mine/classic_mine_heatmap.dart';
import 'package:fqapp/widgets/mine/classic_mine_summary.dart';
import 'package:fqapp/widgets/mine/classic_mine_top_books.dart';
import 'package:fqapp/widgets/settings/settings_widgets.dart';
import 'package:fqapp/widgets/shell_dock.dart';
import 'package:fqapp/widgets/wenku/wenku_ui.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    BookOpenPreferences.instance.resetForTest();
    einkModeNotifier.value = false;
    oledModeNotifier.value = false;
    themeModeNotifier.value = ThemeMode.light;
  });
  tearDown(() {
    einkModeNotifier.value = false;
    oledModeNotifier.value = false;
    themeModeNotifier.value = ThemeMode.system;
  });

  testWidgets('classic settings use the original single card and icon tiles', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_app(const SettingsPage()));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScaffold), findsOneWidget);
    expect(find.byType(SettingsGroupCard), findsOneWidget);
    expect(find.byType(FeatureEntry), findsNothing);
    expect(find.byType(ArchiveMasthead), findsNothing);
    final rows = tester
        .widgetList<SettingsRow>(find.byType(SettingsRow))
        .toList();
    expect(rows.map((row) => row.title), [
      '外观',
      '主题',
      '阅读',
      '听书',
      '短剧',
      '数据',
      '服务',
      '关于',
    ]);
    expect(rows.every((row) => row.iconTile), isTrue);
    expect(rows.first.icon, LucideIcons.palette);
    expect(
      rows.firstWhere((row) => row.title == '阅读').icon,
      LucideIcons.book_open,
    );
    expect(
      rows.firstWhere((row) => row.title == '数据').icon,
      LucideIcons.database,
    );
    final material = tester.widget<Material>(
      find
          .descendant(
            of: find.byType(SettingsGroupCard),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(
      (material.shape! as RoundedRectangleBorder).borderRadius,
      BorderRadius.circular(20),
    );
    await tester.tap(find.byKey(const ValueKey('settings-entry-主题')));
    await tester.pumpAndSettle();
    expect(find.byType(ThemePage), findsOneWidget);
    expect(find.byType(SettingsScaffold), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'classic category controls are original radio dialogs and switches',
    (tester) async {
      await tester.pumpWidget(_app(const SettingsPage()));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-entry-外观')));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsGroupCard), findsOneWidget);
      final modeRow = find.widgetWithText(SettingsRow, '主题模式');
      expect(modeRow, findsOneWidget);
      await tester.tap(modeRow);
      await tester.pumpAndSettle();
      expect(find.byType(SimpleDialog), findsOneWidget);
      expect(find.byType(GlassMenuItem), findsNothing);
      await tester.tap(find.text('跟随系统').last);
      await tester.pumpAndSettle();
      expect(themeModeNotifier.value, ThemeMode.system);
      expect(
        (await SharedPreferences.getInstance()).getString(themeModeKey),
        'system',
      );
      Navigator.of(tester.element(find.byType(SettingsGroupCard))).pop();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-entry-阅读')));
      await tester.pumpAndSettle();
      final row = find.widgetWithText(SettingsRow, '书架点书直接进入阅读');
      expect(row, findsOneWidget);
      expect(
        find.descendant(of: row, matching: find.byType(SettingsSwitch)),
        findsOneWidget,
      );
      expect(find.byType(AppGlassSwitch), findsNothing);
      final before = BookOpenPreferences.instance.shelfDirectReader.value;
      await tester.tap(find.descendant(of: row, matching: find.byType(Switch)));
      await tester.pumpAndSettle();
      expect(BookOpenPreferences.instance.shelfDirectReader.value, !before);
      expect(find.text('AI 阅读优化'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'classic bottom navigation restores four destinations and selection',
    (tester) async {
      var selected = -1;
      await tester.pumpWidget(
        _app(
          Scaffold(
            bottomNavigationBar: ShellDock(
              selectedIndex: 2,
              onSelected: (value) => selected = value,
              overVideo: false,
              staticMaterial: false,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ClassicShellDock), findsOneWidget);
      expect(find.byType(GlassDock), findsNothing);
      // 自定义 dock（不再用 M3 NavigationBar 的 64×32 icon pill）：四个入口
      // 齐全，选中高亮落在“书架”。
      expect(find.byType(NavigationBar), findsNothing);
      for (final label in ['首页', '短剧', '书架', '我的']) {
        expect(find.text(label), findsOneWidget);
      }
      final bar = tester.widget<SizedBox>(
        find.byKey(const ValueKey('classic-navigation-bar')),
      );
      expect(bar.height, 64);
      // 同心圆角：选中背景圆角 28 = 外轮廓 32 − 内缩间距 4；高亮是全局
      // 唯一的浮动背景块，selectedIndex=2 时落在“书架”位置。
      final selection = tester.widget<DecoratedBox>(
        find.byKey(const ValueKey('classic-dock-selection')),
      );
      expect(
        (selection.decoration as BoxDecoration).borderRadius!
            .resolve(TextDirection.ltr)
            .topLeft
            .x,
        28,
      );
      // 背景块中心与“书架”文字中心对齐（屏宽无关）。
      expect(
        tester
            .getRect(find.byKey(const ValueKey('classic-dock-selection')))
            .center
            .dx,
        moreOrLessEquals(
          tester.getRect(find.text('书架')).center.dx,
          epsilon: 1,
        ),
      );
      await tester.tap(find.text('我的'));
      await tester.pumpAndSettle();
      expect(selected, 3);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('desktop keeps its theme route when changing presentation', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final store = AppThemeStyleStore.instance;
      final before = store.value;
      store.value = AppThemeStyle.archive;
      addTearDown(() => store.value = before);
      await tester.pumpWidget(
        ValueListenableBuilder<AppThemeStyle>(
          valueListenable: store,
          builder: (_, style, _) => _app(const SettingsPage(), style: style),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(SettingsRow, '主题'));
      await tester.pumpAndSettle();
      final state = tester.state(find.byType(ThemePage));
      await tester.tap(find.byKey(const ValueKey('theme-choice-classic')));
      await tester.pumpAndSettle();
      expect(store.value, AppThemeStyle.classic);
      expect(tester.state(find.byType(ThemePage)), same(state));
      await tester.tap(find.byKey(const ValueKey('theme-choice-archive')));
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(ThemePage)), same(state));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  group('classic personal page', () {
    late Directory directory;
    setUp(() async {
      directory = await Directory.systemTemp.createTemp(
        'fqapp-classic-profile-',
      );
      Hive.init(directory.path);
      await LibraryStore.instance.init();
    });
    tearDown(() async {
      await Hive.close();
      await directory.delete(recursive: true);
    });

    testWidgets(
      'statistics and original heatmap are on the main personal page',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(400, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
        await tester.runAsync(() async {
          await LibraryStore.instance.addHistory({
            'id': 'classic-profile-book',
            'title': '原有阅读记录',
            'kind': 'book',
            'episode': 2,
          });
          await LibraryStore.instance.accumulateReadTime(
            'classic-profile-book',
            'book',
            420,
          );
        });
        final style = ValueNotifier(AppThemeStyle.classic);
        addTearDown(style.dispose);
        await tester.pumpWidget(
          ValueListenableBuilder<AppThemeStyle>(
            valueListenable: style,
            child: const MinePage(),
            builder: (_, value, child) => _app(child!, style: value),
          ),
        );
        await tester.pumpAndSettle();
        final state = tester.state(find.byType(MinePage));
        expect(find.byType(ClassicMineSummary), findsOneWidget);
        expect(find.byType(ClassicMineHeatmap), findsOneWidget);
        expect(find.byType(ClassicMineTopBooks), findsOneWidget);
        expect(find.byType(ClassicMineEntries), findsOneWidget);
        expect(find.text('今日阅读'), findsOneWidget);
        expect(find.text('阅读热力图'), findsOneWidget);
        expect(find.text('读得最多'), findsOneWidget);
        expect(find.text('原有阅读记录'), findsOneWidget);
        expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('mine-today-minutes')))
              .data,
          '7分钟',
        );
        expect(find.byKey(const ValueKey('mine-statistics')), findsNothing);
        expect(find.byKey(const ValueKey('mine-local-identity')), findsNothing);
        expect(find.byTooltip('应用设置'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('reading-heatmap-cell-111')),
          findsOneWidget,
        );
        final cell = find.byKey(const ValueKey('reading-heatmap-cell-0'));
        await tester.tap(cell);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('reading-heatmap-day')))
              .data,
          endsWith('未阅读'),
        );
        style.value = AppThemeStyle.archive;
        await tester.pumpAndSettle();
        expect(tester.state(find.byType(MinePage)), same(state));
        expect(
          find.byKey(const ValueKey('mine-local-identity')),
          findsOneWidget,
        );
        style.value = AppThemeStyle.classic;
        await tester.pumpAndSettle();
        expect(tester.state(find.byType(MinePage)), same(state));
        expect(find.text('原有阅读记录'), findsOneWidget);
        await tester.tap(find.byTooltip('应用设置'));
        await tester.pumpAndSettle();
        expect(find.byType(SettingsPage), findsOneWidget);
        expect(find.byType(SettingsGroupCard), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  });
}

Widget _app(Widget home, {AppThemeStyle style = AppThemeStyle.classic}) =>
    MaterialApp(
      theme: AppTheme.createTheme(Brightness.light, style: style),
      themeAnimationDuration: Duration.zero,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: true),
        child: child!,
      ),
      home: home,
    );
