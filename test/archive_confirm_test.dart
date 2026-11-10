import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/widgets/wenku/wenku_overlay.dart';

late BuildContext _context;

Future<void> _pumpHost(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: Builder(
            builder: (value) {
              _context = value;
              return const SizedBox(key: Key('anchor'), width: 60, height: 40);
            },
          ),
        ),
      ),
    ),
  );
}

Future<Future<bool>> _open(
  WidgetTester tester, {
  String title = '删除记录',
  bool destructive = true,
}) async {
  final future = confirmArchiveAction(
    _context,
    title: title,
    message: '删除后不可恢复。',
    confirmLabel: '删除',
    destructive: destructive,
    confirmKey: const Key('history-delete-confirm'),
    cancelKey: const Key('history-delete-cancel'),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  return future;
}

void main() {
  testWidgets('only the explicit confirm returns true', (tester) async {
    await _pumpHost(tester);
    final future = await _open(tester);
    expect(find.text('删除记录'), findsOneWidget);
    await tester.tap(find.byKey(const Key('history-delete-confirm')));
    await tester.pumpAndSettle();
    expect(await future, isTrue);
  });

  testWidgets('the cancel row returns false', (tester) async {
    await _pumpHost(tester);
    final future = await _open(tester);
    await tester.tap(find.byKey(const Key('history-delete-cancel')));
    await tester.pumpAndSettle();
    expect(await future, isFalse);
  });

  testWidgets('tapping the barrier returns false', (tester) async {
    await _pumpHost(tester);
    final future = await _open(tester);
    await tester.tapAt(const Offset(6, 6));
    await tester.pumpAndSettle();
    expect(await future, isFalse);
  });

  testWidgets('the system back gesture returns false', (tester) async {
    await _pumpHost(tester);
    final future = await _open(tester);
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.maybePop();
    await tester.pumpAndSettle();
    expect(await future, isFalse);
  });

  testWidgets('a non-destructive confirmation has the same contract', (
    tester,
  ) async {
    await _pumpHost(tester);
    final future = await _open(tester, destructive: false);
    await tester.tap(find.byKey(const Key('history-delete-confirm')));
    await tester.pumpAndSettle();
    expect(await future, isTrue);
  });

  testWidgets('the confirmation names its route after the title', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _pumpHost(tester);
    await _open(tester);
    final node = tester.getSemantics(
      find.byKey(const ValueKey('archive-confirm')),
    );
    expect(node.label, contains('删除记录'));
    semantics.dispose();
  });
}
