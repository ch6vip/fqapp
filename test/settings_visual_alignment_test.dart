import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/pages/about_page.dart';
import 'package:fqapp/pages/api_service_page.dart';
import 'package:fqapp/pages/library_backup_page.dart';
import 'package:fqapp/pages/settings_page.dart';
import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/widgets/settings/settings_widgets.dart';
import 'package:fqapp/widgets/shelf/shelf_design.dart';
import 'package:fqapp/widgets/wenku/settings_glass_controls.dart';
import 'package:fqapp/widgets/wenku/wenku_ui.dart';

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
    for (final title in ['外观', '阅读', '听书', '短剧', '数据', '服务']) {
      expect(find.text(title), findsOneWidget);
    }

    await tester.tap(find.text('外观'));
    await tester.pumpAndSettle();
    expect(find.byType(ArchiveFeaturePage), findsOneWidget);
    expect(find.text('主题模式'), findsOneWidget);
    expect(find.text('浅色'), findsOneWidget);
  });

  testWidgets('设置首页可滚动到「关于」并打开关于页', (tester) async {
    await pumpSettings(tester);
    await tester.scrollUntilVisible(
      find.text('关于'),
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
    expect(find.text('外观'), findsOneWidget);
    await tester.tap(find.text('外观'));
    await tester.pumpAndSettle();

    expect(find.text('主题模式'), findsOneWidget);
    // 墨水屏优先级最高，主题模式的当前值显示「墨水屏」。
    expect(find.text('墨水屏'), findsOneWidget);
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

  testWidgets('本地接口状态点存在，局域网开关走玻璃开关', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.createTheme(Brightness.light),
        home: const ApiServicePage(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(ArchiveFeaturePage), findsOneWidget);
    expect(find.text('已停止'), findsOneWidget);
    expect(find.byKey(const ValueKey('api-status-dot')), findsOneWidget);
    expect(find.byType(AppGlassSwitch), findsOneWidget);
  });

  testWidgets('备份与导入页的分区头和卡片改用 settings 组件', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.createTheme(Brightness.light),
        home: const LibraryBackupPage(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(SettingsSectionHeader), findsNWidgets(2));
    expect(find.byType(SettingsGroupCard), findsNWidgets(3));
    expect(find.byType(SettingsRow), findsNWidgets(3));
    expect(find.text('书架随你走'), findsOneWidget);
  });
}
