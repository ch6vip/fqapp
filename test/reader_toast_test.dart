import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/widgets/reader/reader_toast.dart';

void main() {
  Future<void> mount(
    WidgetTester tester,
    String? message, {
    bool reduce = false,
    bool immediate = false,
  }) => tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduce),
        child: Scaffold(
          body: Stack(
            children: [
              ReaderToast(message: message, immediateDismiss: immediate),
            ],
          ),
        ),
      ),
    ),
  );
  double opacity(WidgetTester tester) => tester
      .widget<FadeTransition>(find.byKey(const ValueKey('reader-toast-fade')))
      .opacity
      .value;

  testWidgets(
    'toast fades in and retains its content until fade out completes',
    (tester) async {
      await mount(tester, '已添加书签');
      expect(opacity(tester), 0);
      await tester.pump(const Duration(milliseconds: 80));
      expect(opacity(tester), inExclusiveRange(0, 1));
      await tester.pump(const Duration(milliseconds: 80));
      expect(opacity(tester), 1);
      await mount(tester, null);
      await tester.pump(const Duration(milliseconds: 100));
      expect(opacity(tester), inExclusiveRange(0, 1));
      expect(find.text('已添加书签'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 120));
      expect(find.byKey(const ValueKey('reader-toast')), findsNothing);
    },
  );

  testWidgets(
    'new notice reverses an outgoing fade without a queue or opacity jump',
    (tester) async {
      await mount(tester, '已添加书签');
      await tester.pumpAndSettle();
      await mount(tester, null);
      await tester.pump(const Duration(milliseconds: 100));
      final before = opacity(tester);
      await mount(tester, '已删除书签');
      expect(opacity(tester), closeTo(before, .001));
      expect(find.text('已添加书签'), findsNothing);
      expect(find.text('已删除书签'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(opacity(tester), 1);
    },
  );

  testWidgets('navigation can immediately clear an already outgoing toast', (
    tester,
  ) async {
    await mount(tester, '已添加书签');
    await tester.pumpAndSettle();
    await mount(tester, null);
    await tester.pump(const Duration(milliseconds: 40));
    await mount(tester, null, immediate: true);
    expect(find.byKey(const ValueKey('reader-toast')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion displays and hides immediately', (tester) async {
    await mount(tester, '已添加书签', reduce: true);
    expect(opacity(tester), 1);
    await mount(tester, null, reduce: true);
    expect(find.byKey(const ValueKey('reader-toast')), findsNothing);
  });
}
