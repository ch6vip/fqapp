import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/reading_stats.dart';

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

  ReadingStats statsOf(Map<String, double> secondsByDay) =>
      ReadingStats.from(history: const [], readTime: {'book': secondsByDay});

  test('this week runs Monday through today across a month boundary', () {
    // 2026-10-01 is a Thursday; its week started on Monday 2026-09-28.
    final stats = statsOf({
      '2026-9-27': 6000, // Sunday of the previous week.
      '2026-9-28': 600,
      '2026-9-30': 1200,
      '2026-10-1': 60,
      '2026-10-2': 9000, // Tomorrow.
    });
    expect(stats.weekMinutes(DateTime(2026, 10, 1)), 31);
    expect(stats.minutesOn(DateTime(2026, 10, 1)), 1);
  });

  test('streak survives a day not read yet and stops at the first gap', () {
    final stats = statsOf({
      '2026-1-1': 60,
      '2026-1-3': 60,
      '2026-1-4': 60,
      '2026-1-5': 60,
    });
    expect(stats.streakDays(DateTime(2026, 1, 5)), 3);
    expect(stats.streakDays(DateTime(2026, 1, 6)), 3);
    expect(stats.streakDays(DateTime(2026, 1, 7)), 0);
    expect(stats.streakDays(DateTime(2026, 1, 2)), 1);
  });

  test('history without measured time counts as a flat estimate', () {
    final time = DateTime(2026, 3, 4, 20).millisecondsSinceEpoch;
    final stats = ReadingStats.from(
      history: [
        {'id': 'old', 'bookId': 'old', 'title': '旧书', 'time': time},
        {'id': 'new', 'bookId': 'new', 'title': '新书', 'time': time},
      ],
      readTime: {
        'new': {'2026-3-4': 3600},
      },
    );
    expect(stats.minutesOn(DateTime(2026, 3, 4)), 60 + flatBookMinutes);
    expect(stats.rank.map((item) => item.title), ['新书', '旧书']);
    expect(stats.rank.last.minutes, flatBookMinutes);
  });

  test('read time without history keeps its content id and kind', () {
    final stats = ReadingStats.from(
      history: const [],
      readTime: {
        'audio:42': {'2026-3-4': 120},
        'orphan': {'2026-3-4': 60},
      },
      readTimeKinds: {'orphan': 'video'},
    );
    final audio = stats.rank.first.entry;
    expect(audio['contentId'], '42');
    expect(audio['kind'], 'audio');
    expect(audio['title'], '听书 42');
    expect(stats.rank.last.entry['kind'], 'video');
  });

  test('durations read as days, hours and minutes', () {
    expect(formatReadingDuration(0), '0分钟');
    expect(formatReadingDuration(59.6), '1小时');
    expect(formatReadingDuration(24 * 60 + 61), '1天1小时1分钟');
  });
}
