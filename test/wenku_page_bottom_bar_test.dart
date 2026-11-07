import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/widgets/wenku/wenku_glass.dart';

void main() {
  testWidgets('WenkuPage forwards bottomNavigationBar to its Scaffold', (
    tester,
  ) async {
    const bar = SizedBox(key: Key('bottom-bar'), height: 72);
    await tester.pumpWidget(
      const MaterialApp(
        home: WenkuPage(bottomNavigationBar: bar, child: Text('主体')),
      ),
    );
    await tester.pumpAndSettle();

    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    expect(scaffold.bottomNavigationBar, same(bar));
    expect(find.byKey(const Key('bottom-bar')), findsOneWidget);
    expect(find.text('主体'), findsOneWidget);
  });

  testWidgets('WenkuPage keeps the bar optional', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: WenkuPage(child: Text('主体'))),
    );
    await tester.pumpAndSettle();
    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    expect(scaffold.bottomNavigationBar, isNull);
  });
}
