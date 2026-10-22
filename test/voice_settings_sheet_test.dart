import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/widgets/audio/voice_settings_sheet.dart';

void main() {
  Future<void> pump(
    WidgetTester tester, {
    required String selectedId,
    required ValueChanged<VoiceOption> onSelect,
    ThemeData? theme,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: theme ?? ThemeData(useMaterial3: true),
        home: Scaffold(
          body: VoiceSettingsSheet(
            selectedId: selectedId,
            narrators: const [VoiceOption(id: 'n1', title: '主播：老恒')],
            online: const [
              VoiceOption(
                id: 't1',
                title: '多角色对话升级版',
                description: '自然流畅',
                badge: '上新',
                isMultiTone: true,
              ),
              VoiceOption(id: 't2', title: '成熟大叔音', description: '超自然'),
            ],
            onSelect: onSelect,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('groups voices into the official sections', (tester) async {
    await pump(tester, selectedId: 't1', onSelect: (_) {});

    expect(find.text('声音设置'), findsOneWidget);
    expect(find.text('真人讲书'), findsOneWidget);
    expect(find.text('智能朗读'), findsOneWidget);
    expect(find.text('主播：老恒'), findsOneWidget);
    expect(find.text('多角色对话升级版'), findsOneWidget);
    expect(find.text('成熟大叔音'), findsOneWidget);
    expect(find.text('上新'), findsOneWidget);
  });

  testWidgets('the selected card carries a check and a tap selects', (
    tester,
  ) async {
    VoiceOption? picked;
    await pump(tester, selectedId: 't1', onSelect: (option) => picked = option);

    final card = find.byKey(const ValueKey('voice_option_t1'));
    expect(
      find.descendant(of: card, matching: find.byIcon(Icons.check)),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('voice_option_t2')));
    expect(picked?.id, 't2');
  });

  testWidgets('the panel carries its own surface so it can be told apart', (
    tester,
  ) async {
    themeModeNotifier.value = ThemeMode.dark;
    oledModeNotifier.value = true;
    addTearDown(() {
      oledModeNotifier.value = false;
      themeModeNotifier.value = ThemeMode.system;
    });
    await pump(
      tester,
      selectedId: 't1',
      onSelect: (_) {},
      theme: AppTheme.createTheme(Brightness.dark, oledMode: true),
    );

    // 面板自己画出比听书页高一档的底色 + 发丝线：纯黑画布上 barrier
    // 叠不出变暗，否则面板和背景连成一片。
    final surface = tester.widget<Material>(
      find.byKey(const Key('voice_settings_surface')),
    );
    expect(surface.color, const Color(0xFF0C0C0E));
    final shape = surface.shape! as RoundedRectangleBorder;
    expect(shape.side.width, 0.8);
    expect(shape.side.color.a, closeTo(0.8, 0.01));
  });

  testWidgets('a hearing-native album shows only the narrator section', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: VoiceSettingsSheet(
            selectedId: 'n1',
            narrators: const [VoiceOption(id: 'n1', title: '主播：佚名')],
            onSelect: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('真人讲书'), findsOneWidget);
    expect(find.text('智能朗读'), findsNothing);
  });
}
