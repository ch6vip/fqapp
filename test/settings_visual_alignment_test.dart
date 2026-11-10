import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart' as easy;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/pages/about_page.dart';
import 'package:fqapp/pages/api_service_page.dart';
import 'package:fqapp/pages/library_backup_page.dart';
import 'package:fqapp/pages/settings_page.dart';
import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/widgets/settings/settings_archive_page.dart';
import 'package:fqapp/widgets/settings/settings_widgets.dart';
import 'package:fqapp/widgets/wenku/wenku_ui.dart';
import 'package:fqapp/widgets/shelf/shelf_design.dart';

/// 设置与「我的」的 Wenku8 档案化收敛：首页是 ArchiveMasthead + 分类
/// FeatureEntry，分类页是 ArchiveFeaturePage + ContentPanel，控制件走
/// GlassSettingMenu / AppGlassSwitch；墨水屏仍退化为纯黑白。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    einkModeNotifier.value = false;
    oledModeNotifier.value = false;
    themeModeNotifier.value = ThemeMode.light;
  });

  tearDown(() {
    einkModeNotifier.value = false;
    oledModeNotifier.value = false;
    themeModeNotifier.value = ThemeMode.system;
  });

  Future<void> pumpSettings(WidgetTester tester, {bool eink = false}) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.createTheme(Brightness.light, einkMode: eink),
        home: const SettingsPage(),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('设置首页使用档案刊头与分类 FeatureEntry', (tester) async {
    await pumpSettings(tester);

    expect(find.byType(ArchiveMasthead), findsOneWidget);
    expect(find.byType(FeatureEntry), findsWidgets);
    expect(find.text('设置'), findsOneWidget);
    for (final title in ['外观', '主题', '阅读', '听书', '短剧', '数据', '服务']) {
      await tester.scrollUntilVisible(
        find.text(title).hitTestable(),
        100,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text(title), findsOneWidget);
    }

    await tester.scrollUntilVisible(
      find.text('外观').hitTestable(),
      -150,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('外观'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsArchivePage), findsOneWidget);
    expect(find.text('主题模式'), findsOneWidget);
    expect(find.text('浅色'), findsOneWidget);
  });

  testWidgets('设置首页可滚动到「关于」并打开关于页', (tester) async {
    await pumpSettings(tester);
    await tester.scrollUntilVisible(
      find.text('关于').hitTestable(),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('关于'), findsOneWidget);
    await tester.tap(find.text('关于'));
    await tester.pumpAndSettle();
    expect(find.byType(AboutPage), findsOneWidget);
  });

  testWidgets('墨水屏下设置首页与分类页保持纯黑白可读', (tester) async {
    einkModeNotifier.value = true;
    await pumpSettings(tester, eink: true);

    expect(find.byType(ArchiveMasthead), findsOneWidget);
    // 分类卡片白底；图标没有调色板着色，落到纯黑。
    final entry = find
        .ancestor(of: find.text('外观'), matching: find.byType(ContentPanel))
        .first;
    final panelMaterial = tester.widget<Material>(
      find.descendant(of: entry, matching: find.byType(Material)).first,
    );
    expect(panelMaterial.color, Colors.white);
    final icon = find
        .descendant(of: entry, matching: find.byType(ArchiveIcon))
        .first;
    expect(tester.widget<ArchiveIcon>(icon).color, isNull);
    final iconColor = IconTheme.of(tester.element(icon)).color!;
    expect([iconColor.r, iconColor.g, iconColor.b], [0, 0, 0]);
    expect(iconColor.a, greaterThan(.8));

    await tester.tap(find.text('外观'));
    await tester.pumpAndSettle();

    expect(find.text('主题模式'), findsOneWidget);
    // 墨水屏优先级最高，主题模式的当前值显示「墨水屏」；尾部值渲染为纯黑。
    final value = find.text('墨水屏');
    expect(value, findsOneWidget);
    final rendered = tester.widget<RichText>(
      find.descendant(of: value, matching: find.byType(RichText)).first,
    );
    expect((rendered.text as TextSpan).style?.color, Colors.black);
    expect(tester.takeException(), isNull);
  });

  testWidgets('清空历史使用破坏性确认框，确认键不再是红色文字按钮', (tester) async {
    await pumpSettings(tester);
    await tester.tap(find.text('数据'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空历史'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '清空'), findsOneWidget);
    expect(find.widgetWithText(TextButton, '清空'), findsNothing);
    final confirm = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '清空'),
    );
    expect(
      confirm.style?.foregroundColor?.resolve(<WidgetState>{}),
      ShelfTokens.deleteRed,
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('本地接口状态点走主题前景色，局域网开关走玻璃开关', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.createTheme(Brightness.light),
        home: const ApiServicePage(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(SettingsArchivePage), findsOneWidget);
    expect(find.text('已停止'), findsOneWidget);
    final dotFinder = find.byKey(const ValueKey('api-status-dot'));
    final dot = tester.widget<Container>(dotFinder);
    // 页面在 WenkuScope 之上构建，颜色取自页面自身的 colorScheme。
    final scheme = Theme.of(
      tester.element(find.byType(ApiServicePage)),
    ).colorScheme;
    final dotColor = (dot.decoration! as BoxDecoration).color;
    expect(dotColor, scheme.onSurfaceVariant);
    expect(dotColor, isNot(Colors.green), reason: '停止状态不再使用 Material 绿');
    expect(dotColor, isNot(scheme.error), reason: '停止状态不再使用 error 红');
    expect(find.byType(AppGlassSwitch), findsOneWidget);
    // 作为根页面时没有可返回的路由，不渲染返回键。
    expect(find.byTooltip('返回'), findsNothing);
  });

  testWidgets('设置主页被 push 时提供返回键', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.createTheme(Brightness.light),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(builder: (_) => const SettingsPage()),
                ),
                child: const Text('打开设置'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开设置'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('返回'), findsOneWidget);

    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    expect(find.text('打开设置'), findsOneWidget);
    expect(find.byType(SettingsPage), findsNothing);
  });

  testWidgets('Windows 双栏分类页不渲染返回键，切换分类不清空右栏', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.createTheme(Brightness.light),
          home: const SettingsPage(),
        ),
      );
      await tester.pumpAndSettle();

      // 右栏默认是外观分类；嵌套 Navigator 只有一条路由，所以没有返回键。
      expect(find.text('主题模式'), findsOneWidget);
      expect(find.byTooltip('返回'), findsNothing);

      await tester.tap(find.widgetWithText(SettingsRow, '服务'));
      await tester.pumpAndSettle();
      expect(find.text('本地接口'), findsOneWidget);
      expect(find.byTooltip('返回'), findsNothing);

      await tester.tap(find.widgetWithText(SettingsRow, '外观'));
      await tester.pumpAndSettle();
      expect(find.text('主题模式'), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('局域网共享在确认前不乐观打开', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.createTheme(Brightness.light),
        home: const ApiServicePage(),
      ),
    );
    await tester.pumpAndSettle();
    final switchFinder = find.byType(AppGlassSwitch);
    expect(tester.widget<AppGlassSwitch>(switchFinder).value, isFalse);

    await tester.tap(switchFinder);
    await tester.pumpAndSettle();
    expect(find.text('开启局域网共享'), findsOneWidget);
    expect(
      tester
          .widget<easy.LiquidGlassSwitch>(find.byType(easy.LiquidGlassSwitch))
          .value,
      isFalse,
    );

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(tester.widget<AppGlassSwitch>(switchFinder).value, isFalse);
    expect(
      tester
          .widget<easy.LiquidGlassSwitch>(find.byType(easy.LiquidGlassSwitch))
          .value,
      isFalse,
    );
  });

  testWidgets('备份与导入页改用档案分区与面板', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.createTheme(Brightness.light),
        home: const LibraryBackupPage(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(ArchiveSection), findsNWidgets(2));
    expect(find.byType(ContentPanel), findsWidgets);
    expect(find.byType(FeatureEntry), findsOneWidget);
    // The three data rows stay individually pinned: export, restore, 番茄.
    expect(find.byKey(const ValueKey('backup-export')), findsOneWidget);
    expect(find.byKey(const ValueKey('backup-import')), findsOneWidget);
    expect(find.byKey(const ValueKey('backup-fanqie')), findsOneWidget);
    expect(find.text('导出备份'), findsOneWidget);
    expect(find.text('从备份文件恢复'), findsOneWidget);
    expect(find.text('导入番茄书架'), findsOneWidget);
    expect(find.byType(SettingsSectionHeader), findsNothing);
    expect(find.byType(SettingsGroupCard), findsNothing);
    expect(find.text('书架随你走'), findsOneWidget);
  });
}
