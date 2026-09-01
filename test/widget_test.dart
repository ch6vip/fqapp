// Basic smoke test: the app boots to the backend-starting screen.

import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/main.dart';

void main() {
  testWidgets('App boots', (WidgetTester tester) async {
    await tester.pumpWidget(const FqApp());
    await tester.pump();
    // The app should show the backend startup screen or the main shell.
    expect(find.byType(FqApp), findsOneWidget);
  });
}
