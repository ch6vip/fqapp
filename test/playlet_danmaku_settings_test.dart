import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/widgets/player/playlet_danmaku_settings.dart';

/// 弹幕设置面板（官方 `ay1/v.java` + `impl/danmaku/a.java`）：
/// 五项设置走官方 `danmaku_config` 的默认值与换算公式。
void main() {
  group('DanmakuSettings', () {
    test('defaults follow the official danmaku_config defaults', () {
      const settings = DanmakuSettings();
      // key_alpha=255、key_speed=NORMAL(3)、key_text_size=DEFAULT(3)。
      expect(settings.alpha, 255);
      expect(settings.speedTier, 3);
      expect(settings.lineCount, 4);
      expect(settings.lineSpaceTier, 2);
      expect(settings.sizeTier, 3);
      expect(settings.fontSize, 16);
      expect(settings.speed, 1.0);
      expect(settings.alphaPercent, 100);
    });

    test('alpha conversion follows the official m(p)/a(alpha) formulas', () {
      // m(p)=(p*255+50)/100、a(alpha)=(alpha*100+127)/255。
      expect(DanmakuSettings.alphaFromPercent(100), 255);
      expect(DanmakuSettings.alphaFromPercent(20), 51);
      expect(const DanmakuSettings(alpha: 128).alphaPercent, 50);
      expect(
        DanmakuSettings.alphaFromPercent(
          const DanmakuSettings(alpha: 51).alphaPercent,
        ),
        51,
      );
    });

    test('tier lookups map to the official enum values', () {
      expect(const DanmakuSettings(speedTier: 1).speed, 0.5);
      expect(const DanmakuSettings(speedTier: 2).speed, 0.7);
      expect(const DanmakuSettings(speedTier: 4).speed, 1.25);
      expect(const DanmakuSettings(speedTier: 5).speed, 1.5);
      expect(const DanmakuSettings(sizeTier: 1).fontSize, 12);
      expect(const DanmakuSettings(sizeTier: 5).fontSize, 20);
    });
  });

  testWidgets('the panel reports slider changes live', (tester) async {
    final changes = <DanmakuSettings>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlayletDanmakuSettingsPanel(
            settings: const DanmakuSettings(),
            landscape: false,
            onChanged: changes.add,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('适中'), findsWidgets);
    expect(find.text('4行'), findsOneWidget);
    expect(find.text('100%'), findsWidgets);

    // 显示区域滑杆（第 3 行）点轨道最左端：值 0 → 1 行。
    final region = tester.getRect(find.byType(Slider).at(2));
    await tester.tapAt(Offset(region.left + 2, region.center.dy));
    await tester.pump();
    expect(changes, isNotEmpty);
    expect(changes.last.lineCount, 1);
    await tester.pumpAndSettle();
    expect(find.text('1行'), findsOneWidget);
  });

  testWidgets('reset restores the official defaults', (tester) async {
    final changes = <DanmakuSettings>[];
    var resets = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlayletDanmakuSettingsPanel(
            settings: const DanmakuSettings(alpha: 100, sizeTier: 5),
            landscape: false,
            onChanged: changes.add,
            onReset: () => resets++,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('大'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('danmaku-settings-reset')));
    await tester.pump();
    expect(resets, 1);
    expect(changes.last, const DanmakuSettings());
    await tester.pumpAndSettle();
    // 复位后 alpha 回 255（100%）、速度回「适中」。
    expect(find.text('39%'), findsNothing);
    expect(find.text('100%'), findsWidgets);
    expect(find.text('适中'), findsWidgets);
  });
}
