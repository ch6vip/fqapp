import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/pages/stats_page.dart';

void main() {
  test('heatmap columns follow calendar weeks for every selected weekday', () {
    for (var day = 1; day <= 7; day++) {
      final selected = DateTime(2026, 9, day);
      final dates = readingHeatmapDates(selected);
      expect(dates, hasLength(112));
      expect(dates.first.weekday, DateTime.monday);
      expect(dates.last.weekday, DateTime.sunday);
      expect(dates, contains(selected));
      expect(dates.last.difference(selected).inDays, lessThan(7));
      for (var column = 0; column < 16; column++) {
        expect(dates[column * 7].weekday, DateTime.monday);
      }
    }
  });

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
