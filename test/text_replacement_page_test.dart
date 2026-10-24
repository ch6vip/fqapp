import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fqapp/pages/text_replacement_page.dart';
import 'package:fqapp/services/text_replacement_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('adds, edits, toggles, reorders and deletes persistent rules', (
    tester,
  ) async {
    final store = TextReplacementStore();
    await store.load();
    await tester.pumpWidget(
      MaterialApp(home: TextReplacementPage(store: store)),
    );
    await tester.pumpAndSettle();
    Future<void> add(String pattern, String replacement) async {
      await tester.tap(find.byKey(const ValueKey('replacement-add')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('replacement-pattern')),
        pattern,
      );
      await tester.enterText(
        find.byKey(const ValueKey('replacement-value')),
        replacement,
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
    }

    await add('漂亮国', '美国');
    await add('霓虹国', '日本');
    expect(store.snapshot.rules.map((r) => r.pattern), ['漂亮国', '霓虹国']);
    await tester.tap(find.byKey(const ValueKey('replacement-up-1')));
    await tester.pumpAndSettle();
    expect(store.snapshot.rules.first.pattern, '霓虹国');
    await tester.tap(find.byKey(const ValueKey('replacement-enabled')));
    await tester.pumpAndSettle();
    expect(store.snapshot.enabled, isTrue);
    await tester.tap(find.byKey(const ValueKey('replacement-edit-0')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('replacement-value')),
      'Japan',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(store.snapshot.rules.first.replacement, 'Japan');
    await tester.tap(find.byKey(const ValueKey('replacement-delete-0')));
    await tester.pumpAndSettle();
    final restored = TextReplacementStore();
    await restored.load();
    expect(restored.snapshot.rules.single.pattern, '漂亮国');
    expect(restored.snapshot.enabled, isTrue);
  });
  testWidgets('empty matching text is rejected without closing editor', (
    tester,
  ) async {
    final store = TextReplacementStore();
    await store.load();
    await tester.pumpWidget(
      MaterialApp(home: TextReplacementPage(store: store)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('replacement-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('匹配内容不能为空'), findsOneWidget);
    expect(store.snapshot.rules, isEmpty);
  });
}
