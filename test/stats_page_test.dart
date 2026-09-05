import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/pages/stats_page.dart';

void main() {
  test('January total does not include October through December', () {
    final minutes = <String, double>{
      '2026-1-2': 10,
      '2026-1-31': 20,
      '2026-10-2': 100,
      '2026-11-2': 200,
      '2026-12-2': 300,
    };

    expect(sumMinutesForMonth(minutes, DateTime(2026, 1)), 30);
    expect(sumMinutesForMonth(minutes, DateTime(2026, 10)), 100);
  });
}
