// Basic smoke test: the app boots to the backend-starting screen.
//
// Wrapped in ProviderScope to mirror main() — HomePage is a ConsumerWidget,
// so any future test that reaches it needs the provider scope present.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/main.dart';

void main() {
  testWidgets('App boots', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: FqApp()));
    await tester.pump();
    // The app should show the backend startup screen or the main shell.
    expect(find.byType(FqApp), findsOneWidget);
  });
}
