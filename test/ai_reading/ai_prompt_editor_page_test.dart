import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/pages/ai_reading/settings/ai_prompt_editor_page.dart';

void main() {
  testWidgets('prompt editor returns the full text', (tester) async {
    String? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await Navigator.of(context).push<String>(
                  MaterialPageRoute(
                    builder: (_) => const AiPromptEditorPage(
                      title: '编辑提示词',
                      initial: '旧内容',
                    ),
                  ),
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.text('旧内容'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).style, isNull);
    await tester.enterText(find.byType(TextField), '新的完整提示词');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(result, '新的完整提示词');
  });

  testWidgets('empty text is rejected for a book prompt', (tester) async {
    String? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await Navigator.of(context).push<String>(
                  MaterialPageRoute(
                    builder: (_) =>
                        const AiPromptEditorPage(title: '编辑本书提示词', initial: ''),
                  ),
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pump();
    expect(find.text('提示词不能为空'), findsOneWidget);
    expect(result, isNull);
  });

  testWidgets('empty text clears a global prompt', (tester) async {
    String? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await Navigator.of(context).push<String>(
                  MaterialPageRoute(
                    builder: (_) => const AiPromptEditorPage(
                      title: '编辑全局提示词',
                      initial: '旧内容',
                      allowEmpty: true,
                    ),
                  ),
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(result, '');
  });
}
