import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/pages/about_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('about page version follows pubspec', (tester) async {
    final pubspec = (await tester.runAsync(
      () => File('pubspec.yaml').readAsString(),
    ))!;
    final match = RegExp(
      r'^version:\s*([0-9]+(?:\.[0-9]+)+)\+([0-9]+)\s*$',
      multiLine: true,
    ).firstMatch(pubspec);
    expect(match, isNotNull, reason: 'pubspec.yaml must declare a version');
    final expected = '${match!.group(1)} (${match.group(2)})';

    await tester.pumpWidget(const MaterialApp(home: AboutPage()));
    expect(find.text(expected), findsOneWidget);
  });
}
