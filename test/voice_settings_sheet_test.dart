import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/widgets/audio/voice_settings_sheet.dart';

void main() {
  Future<void> pump(
    WidgetTester tester, {
    required String selectedId,
    required ValueChanged<VoiceOption> onSelect,
    ValueChanged<VoiceOption>? onDownload,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
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
            offline: const [
              VoiceOption(
                id: 'o1',
                title: '成熟大叔离线版',
                description: '经典',
                offline: true,
              ),
            ],
            onSelect: onSelect,
            onDownload: onDownload,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('groups voices into the official three sections', (tester) async {
    await pump(tester, selectedId: 't1', onSelect: (_) {});

    expect(find.text('声音设置'), findsOneWidget);
    expect(find.text('真人讲书'), findsOneWidget);
    expect(find.text('智能朗读'), findsOneWidget);
    expect(find.text('离线朗读'), findsOneWidget);
    expect(find.text('主播：老恒'), findsOneWidget);
    expect(find.text('多角色对话升级版'), findsOneWidget);
    expect(find.text('成熟大叔音'), findsOneWidget);
    expect(find.text('成熟大叔离线版'), findsOneWidget);
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

  testWidgets('offline cards expose the download action', (tester) async {
    VoiceOption? downloaded;
    await pump(
      tester,
      selectedId: 't1',
      onSelect: (_) {},
      onDownload: (option) => downloaded = option,
    );

    await tester.tap(find.byKey(const ValueKey('voice_download_o1')));
    expect(downloaded?.id, 'o1');
  });
}
