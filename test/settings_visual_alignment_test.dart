import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/pages/api_service_page.dart';
import 'package:fqapp/pages/library_backup_page.dart';
import 'package:fqapp/pages/settings_page.dart';
import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/widgets/home/home_back_button.dart';
import 'package:fqapp/widgets/home/home_design.dart';
import 'package:fqapp/widgets/settings/settings_widgets.dart';
import 'package:fqapp/widgets/shelf/shelf_design.dart';

/// 设置与「我的」这一组的视觉收敛：分类行、尾部值、清空确认、接口页状态
/// 全部走 [HomePalette] / settings 组件，墨水屏退化为纯黑白。
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

  Finder rowOf(String label) =>
      find.ancestor(of: find.text(label), matching: find.byType(SettingsRow));

  testWidgets('设置首页分类行统一使用 soft 图标砖，尾部值用 muted', (tester) async {
    await pumpSettings(tester);

    expect(find.byType(SettingsRow), findsNWidgets(7));
    final tile = tester.widget<Container>(
      find.descendant(of: rowOf('外观'), matching: find.byType(Container)).first,
    );
    expect(
      (tile.decoration! as BoxDecoration).color,
      const HomePalette(false).soft,
    );
    final icon = tester.widget<Icon>(
      find.descendant(of: rowOf('外观'), matching: find.byType(Icon)).first,
    );
    expect(icon.color, const HomePalette(false).accentText);

    await tester.tap(find.text('外观'));
    await tester.pumpAndSettle();
    final value = tester.widget<Text>(find.text('浅色'));
    expect(value.style?.color, const HomePalette(false).muted);
  });

  testWidgets('墨水屏下分类图标砖白底黑图标，尾部值纯黑可辨', (tester) async {
    einkModeNotifier.value = true;
    await pumpSettings(tester, eink: true);

    final tile = tester.widget<Container>(
      find.descendant(of: rowOf('外观'), matching: find.byType(Container)).first,
    );
    expect((tile.decoration! as BoxDecoration).color, Colors.white);
    final icon = tester.widget<Icon>(
      find.descendant(of: rowOf('外观'), matching: find.byType(Icon)).first,
    );
    expect(icon.color, Colors.black);

    await tester.tap(find.text('外观'));
    await tester.pumpAndSettle();
    // 墨水屏优先级最高，主题模式的尾部值显示「墨水屏」。
    expect(tester.widget<Text>(find.text('墨水屏')).style?.color, Colors.black);
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

  testWidgets('本地接口状态点走 palette，局域网开关用 SettingsSwitch', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.createTheme(Brightness.light),
        home: const ApiServicePage(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('已停止'), findsOneWidget);
    expect(find.byType(SettingsSwitch), findsOneWidget);
    expect(find.byType(HomeBackButton), findsOneWidget);
    final dot = tester.widget<Container>(
      find.byKey(const ValueKey('api-status-dot')),
    );
    expect(
      (dot.decoration! as BoxDecoration).color,
      const HomePalette(false).muted,
      reason: '停止状态不再使用 Material 绿 / error 红',
    );
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
