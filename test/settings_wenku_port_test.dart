import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart' as easy;

import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/widgets/settings/settings_archive_rows.dart';
import 'package:fqapp/widgets/wenku/glass_controls.dart';
import 'package:fqapp/widgets/wenku/wenku_segments.dart';
import 'package:fqapp/widgets/wenku/setting_menu.dart';
import 'package:fqapp/widgets/wenku/wenku_overlay.dart';
import 'package:fqapp/widgets/wenku/wenku_theme.dart';

/// 设置单元新移植组件的聚焦回归：setting_menu.dart 的 GlassSettingMenu /
/// GlassMenuItem 与 glass_controls.dart 的 AppGlassSwitch。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    einkModeNotifier.value = false;
    themeModeNotifier.value = ThemeMode.system;
  });

  Future<void> pumpMenu(
    WidgetTester tester, {
    required ValueChanged<String> onChanged,
    String value = 'a',
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.createTheme(Brightness.light),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 360,
              child: GlassSettingMenu<String>(
                icon: Icons.tune,
                label: '测试项目',
                value: value,
                options: const {'a': '选项甲', 'b': '选项乙'},
                reduceMotion: true,
                onChanged: onChanged,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('GlassSettingMenu 打开档案弹层、回传选择并关闭', (tester) async {
    String? picked;
    await pumpMenu(tester, onChanged: (value) => picked = value);

    expect(find.text('测试项目'), findsOneWidget);
    expect(find.text('选项甲'), findsOneWidget);

    await tester.tap(find.text('选项甲'));
    await tester.pumpAndSettle();
    expect(find.byType(GlassMenuItem), findsNWidgets(2));
    // 当前值在菜单里带选中态。
    expect(
      tester
          .widget<GlassMenuItem>(
            find.ancestor(
              of: find.descendant(
                of: find.byType(GlassMenuItem),
                matching: find.text('选项甲'),
              ),
              matching: find.byType(GlassMenuItem),
            ),
          )
          .selected,
      isTrue,
    );

    await tester.tap(
      find.descendant(
        of: find.byType(GlassMenuItem),
        matching: find.text('选项乙'),
      ),
    );
    await tester.pumpAndSettle();
    expect(picked, 'b');
    expect(find.byType(GlassMenuItem), findsNothing);
  });

  testWidgets('GlassSettingMenu 选择当前值不回调', (tester) async {
    var calls = 0;
    await pumpMenu(tester, onChanged: (_) => calls++);

    await tester.tap(find.text('选项甲'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(GlassMenuItem),
        matching: find.text('选项甲'),
      ),
    );
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(find.byType(GlassMenuItem), findsNothing);
  });

  testWidgets('SettingsToggleRow 整行可点并渲染玻璃开关', (tester) async {
    bool? changed;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.createTheme(Brightness.light),
        home: Scaffold(
          body: SettingsToggleRow(
            icon: Icons.tune,
            title: '测试开关',
            description: '说明文字',
            value: false,
            onChanged: (value) => changed = value,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AppGlassSwitch), findsOneWidget);
    await tester.tap(find.text('测试开关'));
    await tester.pumpAndSettle();
    expect(changed, isTrue);
  });

  testWidgets('禁用态玻璃开关只由控件降一次透明度', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.createTheme(Brightness.light),
        home: WenkuScope(
          child: Scaffold(
            body: Builder(
              builder: (context) => Column(
                children: [
                  GlassControls.toggle(
                    context,
                    value: false,
                    onChanged: (_) {},
                  ),
                  GlassControls.toggle(context, value: false, onChanged: null),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final switches = tester
        .widgetList<AppGlassSwitch>(find.byType(AppGlassSwitch))
        .toList();
    expect(switches, hasLength(2));
    // 适配器传原值；禁用态的 .4/.5/.55 由 AppGlassSwitch 自己叠加一次。
    expect(switches[1].activeColor, switches[0].activeColor);
    expect(switches[1].inactiveColor, switches[0].inactiveColor);
    expect(switches[1].thumbColor, switches[0].thumbColor);
  });

  testWidgets('非乐观开关在回调提交前保持原值', (tester) async {
    final gate = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.createTheme(Brightness.light),
        home: Scaffold(
          body: SettingsToggleRow(
            icon: Icons.tune,
            title: '需要授权',
            description: '权限返回后才生效',
            value: false,
            optimistic: false,
            onChanged: (_) => gate.future,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(AppGlassSwitch));
    await tester.pump();
    await tester.pump();
    // 回调还挂着时，传给玻璃开关的仍是持久化的 false。
    expect(
      tester
          .widget<easy.LiquidGlassSwitch>(find.byType(easy.LiquidGlassSwitch))
          .value,
      isFalse,
    );

    gate.complete();
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<easy.LiquidGlassSwitch>(find.byType(easy.LiquidGlassSwitch))
          .value,
      isFalse,
    );
  });

  testWidgets('墨水屏下玻璃开关仍是黑白两态', (tester) async {
    einkModeNotifier.value = true;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.createTheme(Brightness.light),
        home: WenkuScope(
          child: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: GlassControls.toggle(
                  context,
                  value: false,
                  onChanged: (_) {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final off = tester.widget<AppGlassSwitch>(find.byType(AppGlassSwitch));
    expect(off.thumbColor, isNot(off.inactiveColor));

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.createTheme(Brightness.light),
        home: WenkuScope(
          child: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: GlassControls.toggle(
                  context,
                  value: true,
                  onChanged: (_) {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final on = tester.widget<AppGlassSwitch>(find.byType(AppGlassSwitch));
    // 开态拇指与关态轨道同色：两态在灰度上完全相反。
    expect(on.thumbColor, off.inactiveColor);
    expect(on.activeColor, off.thumbColor);
  });
}
