import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/pages/about_page.dart';

/// The about page shows a static version string (no package_info dependency),
/// so this guard keeps it from silently drifting away from pubspec.yaml after
/// a version bump — the release flow only touches the pubspec.
void main() {
  test('about page version matches pubspec.yaml', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final match = RegExp(
      r'^version:\s*(\d+)\.(\d+)\.(\d+)\+(\d+)\s*$',
      multiLine: true,
    ).firstMatch(pubspec);
    expect(match, isNotNull, reason: 'pubspec.yaml must declare a version');
    final expected =
        '${match!.group(1)}.${match.group(2)}.${match.group(3)} '
        '(${match.group(4)})';
    expect(AboutPage.versionText, expected);
  });
}
