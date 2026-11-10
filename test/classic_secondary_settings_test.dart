import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/library_backup.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/about_page.dart';
import 'package:fqapp/pages/api_service_page.dart';
import 'package:fqapp/pages/fanqie_history_import_page.dart';
import 'package:fqapp/pages/library_backup_page.dart';
import 'package:fqapp/pages/log_viewer_page.dart';
import 'package:fqapp/pages/reading_statistics_page.dart';
import 'package:fqapp/pages/settings_page.dart';
import 'package:fqapp/pages/system_tts_settings_page.dart';
import 'package:fqapp/pages/text_replacement_page.dart';
import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/services/app_theme_style.dart';
import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/services/shelf_store.dart';
import 'package:fqapp/services/text_replacement_store.dart';
import 'package:fqapp/widgets/home/home_feed_states.dart';
import 'package:fqapp/widgets/mine/classic_mine_heatmap.dart';
import 'package:fqapp/widgets/mine/classic_mine_summary.dart';
import 'package:fqapp/widgets/mine/classic_mine_top_books.dart';
import 'package:fqapp/widgets/mine/mine_summary.dart';
import 'package:fqapp/widgets/settings/settings_widgets.dart';
import 'package:fqapp/widgets/wenku/wenku_ui.dart';

import 'support/app_ui_host.dart';

/// The secondary settings pages (API console, logs, text replacement, system
/// TTS, about, backup/import, 番茄 import, statistics) under both presentations.
///
/// Classic restores the pre-#291 fqapp-backup@f329399 vocabulary
/// (SettingsGroupCard / SettingsRow / SettingsSwitch / HomeStateView / fixed
/// bottom bars). Archive keeps the Wenku8 surfaces #291 introduced
/// (ArchiveSection / ContentPanel / GlassTextButton / ContentNotice). Each test
/// drives the real page State, then switches the live style to prove the same
/// body keeps working, which is the archive regression for that page.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    einkModeNotifier.value = false;
    oledModeNotifier.value = false;
    themeModeNotifier.value = ThemeMode.light;
    // Local stores back the statistics and backup pages. Initialise them
    // outside the fake-async test body: real file IO never completes there.
    directory = await Directory.systemTemp.createTemp('fqapp-secondary-');
    Hive.init(directory.path);
    await LibraryStore.instance.init();
    await ShelfStore.instance.init();
  });

  tearDown(() async {
    einkModeNotifier.value = false;
    oledModeNotifier.value = false;
    themeModeNotifier.value = ThemeMode.system;
    await Hive.close().timeout(
      const Duration(seconds: 10),
      onTimeout: () => const <void>[],
    );
    try {
      await directory.delete(recursive: true);
    } catch (_) {
      // Temp directory cleanup is noise.
    }
  });

  Future<AppThemeStyleStore> pumpStyled(
    WidgetTester tester,
    Widget page, {
    AppThemeStyle style = AppThemeStyle.classic,
    Size size = const Size(400, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final store = AppThemeStyleStore()..value = style;
    addTearDown(store.dispose);
    await tester.pumpWidget(AppUiHost(store: store, home: page));
    await tester.pumpAndSettle();
    return store;
  }

  testWidgets('classic API console keeps the pre-#291 cards and actions', (
    tester,
  ) async {
    final store = await pumpStyled(tester, const ApiServicePage());

    expect(find.byType(SettingsScaffold), findsOneWidget);
    expect(find.byType(WenkuPage), findsNothing);
    expect(find.text('本地接口'), findsOneWidget);
    expect(find.byType(SettingsGroupCard), findsWidgets);
    expect(find.byType(ContentPanel), findsNothing);
    // LAN sharing is the Material switch again, not the archive lens.
    expect(find.byType(Switch), findsWidgets);
    expect(find.byType(AppGlassSwitch), findsNothing);
    expect(find.text('局域网共享'), findsOneWidget);

    // Endpoint reference still expands, and rows still copy through the same
    // callbacks.
    await tester.tap(find.text('查看可用接口'));
    await tester.pumpAndSettle();
    expect(find.text('隐藏接口'), findsOneWidget);
    for (final endpoint in ['搜索', '详情', '目录', '正文']) {
      expect(find.text(endpoint), findsOneWidget);
    }
    expect(find.text('运行日志'), findsOneWidget);

    // Live switch to archive keeps the same page and State.
    store.value = AppThemeStyle.archive;
    await tester.pumpAndSettle();
    expect(find.byType(WenkuPage), findsOneWidget);
    expect(find.byType(SettingsScaffold), findsNothing);
    expect(find.byType(AppGlassSwitch), findsOneWidget);
    // The toggled endpoint list survived the switch.
    expect(find.text('隐藏接口'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'classic log page keeps the settings AppBar and its empty state',
    (tester) async {
      final store = await pumpStyled(tester, const LogViewerPage());

      expect(find.byType(SettingsScaffold), findsOneWidget);
      expect(find.byType(WenkuPage), findsNothing);
      expect(find.text('日志'), findsOneWidget);
      expect(find.byTooltip('日志操作'), findsOneWidget);
      expect(find.byType(HomeStateView), findsOneWidget);
      expect(find.byType(ContentNotice), findsNothing);
      expect(find.text('暂无日志'), findsOneWidget);

      await tester.tap(find.byTooltip('日志操作'));
      await tester.pumpAndSettle();
      expect(find.text('清空当前视图'), findsOneWidget);
      await tester.tapAt(const Offset(8, 8));
      await tester.pumpAndSettle();

      await tester.tap(find.text('核心'));
      await tester.pumpAndSettle();
      expect(find.text('暂无核心日志'), findsOneWidget);

      store.value = AppThemeStyle.archive;
      await tester.pumpAndSettle();
      expect(find.byType(WenkuPage), findsOneWidget);
      expect(find.byType(ContentNotice), findsOneWidget);
      expect(find.byType(HomeStateView), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('classic text replacement saves a drafted rule across a switch', (
    tester,
  ) async {
    final store = TextReplacementStore();
    await store.load();
    final styleStore = await pumpStyled(
      tester,
      TextReplacementPage(store: store),
    );

    expect(find.byType(AppBar), findsOneWidget);
    expect(find.byType(WenkuPage), findsNothing);
    expect(find.byType(ContentNotice), findsNothing);
    expect(find.text('还没有替换规则'), findsOneWidget);
    // The enable row is a classic SettingsRow with a Material switch.
    expect(find.byKey(const ValueKey('replacement-enabled')), findsOneWidget);
    expect(find.byType(Switch), findsOneWidget);
    expect(find.byType(AppGlassSwitch), findsNothing);
    // The add action sits in the fixed bottom bar as a filled button.
    expect(find.widgetWithText(FilledButton, '添加规则'), findsOneWidget);
    expect(find.byType(GlassPillButton), findsNothing);

    // Draft a rule, then switch presentation before saving: the dialog keeps
    // its text and the page keeps its State.
    await tester.tap(find.byKey(const ValueKey('replacement-add')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('replacement-pattern')),
      '漂亮国',
    );
    await tester.enterText(
      find.byKey(const ValueKey('replacement-value')),
      '美国',
    );
    styleStore.value = AppThemeStyle.archive;
    await tester.pumpAndSettle();
    expect(find.text('漂亮国'), findsOneWidget);
    expect(find.text('美国'), findsOneWidget);

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(store.snapshot.rules.single.pattern, '漂亮国');
    expect(store.snapshot.rules.single.replacement, '美国');
    // The saved rule renders with the archive row vocabulary now.
    expect(find.byKey(const ValueKey('replacement-edit-0')), findsOneWidget);
    expect(find.text('漂亮国'), findsOneWidget);
    expect(find.byType(GlassPillButton), findsOneWidget);
    expect(find.byType(Switch), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('classic system TTS keeps the Material picker and slider', (
    tester,
  ) async {
    const channel = MethodChannel('fqapp/system_tts');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'engines') {
        return {
          'engines': [
            {'package': 'com.example.tts', 'label': '示例引擎'},
          ],
          'defaultEngine': 'com.example.tts',
        };
      }
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );

    final store = await pumpStyled(tester, const SystemTtsSettingsPage());

    expect(find.byType(SettingsScaffold), findsOneWidget);
    expect(find.byType(WenkuPage), findsNothing);
    expect(find.byType(SettingsGroupCard), findsOneWidget);
    expect(find.byType(DropdownButton<String>), findsOneWidget);
    expect(find.byType(Slider), findsOneWidget);
    expect(find.byType(GlassSettingMenu<String>), findsNothing);
    expect(find.byType(AppGlassSlider), findsNothing);
    expect(find.text('示例引擎', skipOffstage: false), findsWidgets);
    expect(find.widgetWithText(OutlinedButton, '打开系统语音设置'), findsOneWidget);

    store.value = AppThemeStyle.archive;
    await tester.pumpAndSettle();
    expect(find.byType(WenkuPage), findsOneWidget);
    expect(find.byType(GlassSettingMenu<String>), findsOneWidget);
    expect(find.byType(AppGlassSlider), findsOneWidget);
    expect(find.byType(DropdownButton<String>), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('classic about keeps SettingsRows, the licence route and 赞赏', (
    tester,
  ) async {
    final store = await pumpStyled(
      tester,
      const AboutPage(),
      size: const Size(800, 1800),
    );

    expect(find.byType(SettingsScaffold), findsOneWidget);
    expect(find.byType(WenkuPage), findsNothing);
    expect(find.byType(SettingsGroupCard), findsOneWidget);
    expect(find.byType(ContentPanel), findsNothing);
    for (final title in ['当前版本', '检查更新', '开源许可', '源代码', '问题反馈']) {
      expect(find.text(title), findsOneWidget);
    }
    expect(find.text(AboutPage.versionText), findsOneWidget);
    // The fqapp-only sponsor card and 赞赏 stay on the classic page.
    expect(find.text('支持作者'), findsOneWidget);
    expect(find.text('前往爱发电'), findsOneWidget);
    expect(find.text('微信赞赏'), findsOneWidget);

    await tester.tap(find.text('开源许可'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(LicensePage), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.tap(find.text('微信赞赏'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.text('微信扫一扫，赞赏作者'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();

    store.value = AppThemeStyle.archive;
    await tester.pumpAndSettle();
    expect(find.byType(WenkuPage), findsOneWidget);
    expect(find.byType(ContentPanel), findsOneWidget);
    expect(find.byType(SettingsRow), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('classic statistics uses the 我的 vocabulary', (tester) async {
    final store = await pumpStyled(
      tester,
      const ReadingStatisticsPage(),
      size: const Size(400, 1200),
    );

    expect(find.byType(SettingsScaffold), findsOneWidget);
    expect(find.byType(WenkuPage), findsNothing);
    expect(find.byType(ClassicMineSummary), findsOneWidget);
    expect(find.byType(ClassicMineHeatmap), findsOneWidget);
    expect(find.byType(ClassicMineTopBooks), findsOneWidget);
    expect(find.byType(MineSummary), findsNothing);
    // The current statistics are still a single scroll: overview, rhythm,
    // calendar, most-read.
    expect(find.textContaining('当前文库'), findsOneWidget);
    expect(find.text('阅读节律'), findsOneWidget);

    store.value = AppThemeStyle.archive;
    await tester.pumpAndSettle();
    expect(find.byType(WenkuPage), findsOneWidget);
    expect(find.byType(ClassicMineSummary), findsNothing);
    expect(find.byType(ArchiveSection), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('classic 番茄 import keeps its source rows and no archive panel', (
    tester,
  ) async {
    const files = MethodChannel('fqapp/library_backup');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      files,
      (call) async => null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        files,
        null,
      ),
    );

    final store = await pumpStyled(tester, const FanqieHistoryImportPage());

    expect(find.byType(AppBar), findsOneWidget);
    expect(find.byType(WenkuPage), findsNothing);
    expect(find.text('导入番茄书架'), findsOneWidget);
    expect(find.text('从番茄账号读取'), findsOneWidget);
    expect(find.text('从历史文件导入'), findsOneWidget);
    expect(find.byType(SettingsGroupCard), findsOneWidget);
    expect(find.byType(SettingsRow), findsNWidgets(2));
    expect(find.byType(GlassTextButton), findsNothing);
    expect(find.byTooltip('登录管理'), findsOneWidget);

    store.value = AppThemeStyle.archive;
    await tester.pumpAndSettle();
    expect(find.byType(WenkuPage), findsOneWidget);
    expect(find.byType(GlassTextButton), findsWidgets);
    expect(find.byType(SettingsRow), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('classic backup keeps the fixed restore bar and group counts', (
    tester,
  ) async {
    const channel = MethodChannel('fqapp/library_backup');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'openBackup') return _groupedBackupBytes();
      if (call.method == 'saveBackup') return true;
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );

    final store = await pumpStyled(tester, const LibraryBackupPage());

    expect(find.byType(AppBar), findsOneWidget);
    expect(find.byType(WenkuPage), findsNothing);
    for (final title in ['导出备份', '按书导出 AI 资产', '从备份文件恢复', '导入番茄书架']) {
      expect(find.text(title), findsOneWidget);
    }
    expect(find.byType(SettingsGroupCard), findsWidgets);
    expect(find.byType(FeatureEntry), findsNothing);
    expect(find.byType(ArchiveSection), findsNothing);

    // Picking a backup runs real decode work; pump it outside fake async.
    await tester.runAsync(() async {
      await tester.tap(find.text('从备份文件恢复'));
    });
    for (var i = 0; i < 200; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      if (find.text('分组').evaluate().isNotEmpty) break;
    }
    await tester.pumpAndSettle();

    // Group compatibility copy and counts survive under the classic chips.
    expect(find.text('恢复预览'), findsOneWidget);
    expect(find.text('分组'), findsOneWidget);
    expect(find.text('归属'), findsOneWidget);
    expect(find.textContaining('只补充缺失的收藏、进度与分组'), findsOneWidget);
    // The pre-#291 page keeps its confirmation in the fixed bottom bar.
    expect(find.widgetWithText(FilledButton, '确认恢复到本机'), findsOneWidget);

    store.value = AppThemeStyle.archive;
    await tester.pumpAndSettle();
    expect(find.byType(WenkuPage), findsOneWidget);
    expect(find.byType(ArchiveSection), findsNWidgets(3));
    expect(find.byType(FeatureEntry), findsNWidgets(2));
    expect(find.text('确认恢复到本机'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('classic Windows two-pane settings nests secondary pages', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final store = await pumpStyled(
        tester,
        const SettingsPage(),
        size: const Size(1280, 800),
      );

      // The nested Navigator holds exactly one route: no back affordance, and
      // the classic API page keeps its own classic AppBar inside the pane.
      await tester.tap(find.widgetWithText(SettingsRow, '服务'));
      await tester.pumpAndSettle();
      expect(find.text('本地接口'), findsOneWidget);
      expect(find.byType(SettingsScaffold), findsOneWidget);
      expect(find.byTooltip('返回'), findsNothing);

      await tester.tap(find.widgetWithText(SettingsRow, '关于'));
      await tester.pumpAndSettle();
      expect(find.text('什锦铺'), findsOneWidget);
      expect(find.byType(SettingsScaffold), findsOneWidget);
      expect(find.byTooltip('返回'), findsNothing);

      await tester.tap(find.widgetWithText(SettingsRow, '数据'));
      await tester.pumpAndSettle();
      expect(find.text('备份与导入'), findsOneWidget);
      expect(find.byType(AppBar), findsOneWidget);

      // A secondary page pushed inside the pane keeps a working back button
      // and still gets back to the category list.
      await tester.tap(find.widgetWithText(SettingsRow, '备份与导入'));
      await tester.pumpAndSettle();
      expect(find.text('书架随你走'), findsOneWidget);
      expect(find.byType(AppBar), findsOneWidget);
      expect(find.byTooltip('返回'), findsOneWidget);
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(SettingsRow, '备份与导入'), findsOneWidget);
      expect(find.text('书架随你走'), findsNothing);

      // Switching presentation keeps the nested pane and its route. The
      // archive shell derives `canPop` the same way, so the single embedded
      // route still has no back affordance.
      store.value = AppThemeStyle.archive;
      await tester.pumpAndSettle();
      expect(find.text('备份与导入'), findsOneWidget);
      // The settings shell itself is a WenkuPage; the nested pane switched to
      // the archive feature shell.
      expect(find.byType(WenkuPage), findsWidgets);
      expect(find.byType(SettingsScaffold), findsNothing);
      expect(find.byTooltip('返回'), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

/// 2 个分组、3 条归属、1 条收藏、1 条进度，用于验证经典统计块里的分组计数。
Uint8List _groupedBackupBytes() {
  final backup = LibraryBackup.capture(
    shelf: [
      ShelfRecord(
        item: MediaItem(
          id: '1',
          title: '作品',
          cover: '',
          author: '',
          badge: '',
          ep: '',
          kind: 'book',
        ),
        addedAt: DateTime(2020),
      ),
    ],
    history: [
      {'id': '1', 'kind': 'book'},
    ],
    watched: {},
    groups: {
      'version': 1,
      'groups': {
        'g1-a': {'name': '想读', 'at': 1, 'deleted': false},
        'g2-b': {'name': '在读', 'at': 2, 'deleted': false},
      },
      'assignments': {
        'book:1': {'group': 'g1-a', 'at': 1},
        'book:2': {'group': 'g1-a', 'at': 2},
        'book:3': {'group': 'g2-b', 'at': 3},
      },
    },
  );
  return backup.encode();
}
