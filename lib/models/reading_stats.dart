import '../services/media_history_store.dart';

/// Pre-tracking history entries have no measured time; each one counts as a
/// flat estimate until the book records real reading time.
const double flatBookMinutes = 10;

/// One book in 读得最多, with its measured (or estimated) total minutes.
class ReadingRankItem {
  final Map<String, dynamic> entry;
  final double minutes;

  const ReadingRankItem({required this.entry, required this.minutes});

  String get title => entry['title']?.toString() ?? '未知';
}

/// Aggregates the local reading history and the measured read-time map into
/// what 我的 shows. Pure: callers pass store snapshots and a clock.
class ReadingStats {
  /// Minutes per unpadded Hive day key (`2026-1-2`).
  final Map<String, double> dayMinutes;

  /// Books sorted by total minutes, longest first.
  final List<ReadingRankItem> rank;

  const ReadingStats._(this.dayMinutes, this.rank);

  static const empty = ReadingStats._({}, []);

  factory ReadingStats.from({
    required List<Map<String, dynamic>> history,
    required Map<String, Map<String, double>> readTime,
    Map<String, String> readTimeKinds = const {},
  }) => ReadingStats._(
    _dayMinutesOf(history, readTime),
    _rankOf(history, readTime, readTimeKinds),
  );

  bool get isEmpty => dayMinutes.isEmpty;

  double get totalMinutes => dayMinutes.values.fold(0, (a, b) => a + b);

  double minutesOn(DateTime day) => dayMinutes[readingDayKey(day)] ?? 0;

  /// Monday through [today] of the current calendar week.
  double weekMinutes(DateTime today) {
    var sum = 0.0;
    for (var back = 0; back < today.weekday; back++) {
      sum += minutesOn(DateTime(today.year, today.month, today.day - back));
    }
    return sum;
  }

  /// Consecutive days with reading, ending today. A day not yet read keeps
  /// yesterday's streak alive, so the count does not drop to 0 at midnight.
  int streakDays(DateTime today) {
    var day = DateTime(today.year, today.month, today.day);
    if (minutesOn(day) <= 0) day = DateTime(day.year, day.month, day.day - 1);
    var streak = 0;
    while (minutesOn(day) > 0) {
      streak++;
      day = DateTime(day.year, day.month, day.day - 1);
    }
    return streak;
  }
}

String readingDayKey(DateTime d) => '${d.year}-${d.month}-${d.day}';

/// Sixteen calendar weeks, with Monday in the first row of every column.
List<DateTime> readingHeatmapDates(DateTime selected) {
  final start = DateTime(
    selected.year,
    selected.month,
    selected.day - (selected.weekday - DateTime.monday) - 15 * 7,
  );
  return [
    for (var index = 0; index < 112; index++)
      DateTime(start.year, start.month, start.day + index),
  ];
}

/// Heatmap intensity 0–4 for a day's minutes.
int readingHeatLevel(double minutes) {
  if (minutes <= 0) return 0;
  if (minutes < 10) return 1;
  if (minutes < 30) return 2;
  if (minutes < 60) return 3;
  return 4;
}

String formatReadingDuration(double minutes) {
  final totalMin = minutes.round();
  if (totalMin <= 0) return '0分钟';
  final days = totalMin ~/ (24 * 60);
  final hours = (totalMin % (24 * 60)) ~/ 60;
  final mins = totalMin % 60;
  return [
    if (days > 0) '$days天',
    if (hours > 0) '$hours小时',
    if (mins > 0) '$mins分钟',
  ].join();
}

Map<String, double> _dayMinutesOf(
  List<Map<String, dynamic>> history,
  Map<String, Map<String, double>> readTime,
) {
  final map = <String, double>{};
  void add(String day, double minutes) => map[day] = (map[day] ?? 0) + minutes;
  // Real recorded reading time (seconds → minutes).
  for (final days in readTime.values) {
    days.forEach((day, secs) => add(day, secs / 60));
  }
  // Fallback estimates for books without real data yet, so older history
  // still shows up during the transition. Drops out once real data exists.
  for (final entry in history) {
    if (readTime.containsKey(historyStatisticsId(entry))) continue;
    final time = (entry['time'] as num?)?.toInt() ?? 0;
    add(
      readingDayKey(DateTime.fromMillisecondsSinceEpoch(time)),
      flatBookMinutes,
    );
  }
  return map;
}

List<ReadingRankItem> _rankOf(
  List<Map<String, dynamic>> history,
  Map<String, Map<String, double>> readTime,
  Map<String, String> readTimeKinds,
) {
  final byBook = <String, ReadingRankItem>{};
  readTime.forEach((bookId, days) {
    final minutes = days.values.fold<double>(0, (a, b) => a + b) / 60;
    if (minutes <= 0) return;
    final entry = history.firstWhere(
      (e) => historyStatisticsId(e) == bookId,
      orElse: () => _historyForStatisticsId(bookId, readTimeKinds[bookId]),
    );
    byBook[bookId] = ReadingRankItem(entry: entry, minutes: minutes);
  });
  for (final entry in history) {
    final id = historyStatisticsId(entry);
    if (readTime.containsKey(id)) continue;
    final existing = byBook[id];
    byBook[id] = ReadingRankItem(
      entry: existing?.entry ?? entry,
      minutes: (existing?.minutes ?? 0) + flatBookMinutes,
    );
  }
  return byBook.values.toList()..sort((a, b) => b.minutes.compareTo(a.minutes));
}

/// A history-shaped entry for read time whose history row was cleared, so
/// 读得最多 can still reopen the original content and kind.
Map<String, dynamic> _historyForStatisticsId(String id, [String? storedKind]) {
  for (final kind in const {'audio': '听书', 'manga': '漫画'}.entries) {
    final prefix = '${kind.key}:';
    if (!id.startsWith(prefix) || id.length == prefix.length) continue;
    final contentId = id.substring(prefix.length);
    return {
      'id': id,
      'bookId': contentId,
      'contentId': contentId,
      'kind': kind.key,
      'title': '${kind.value} $contentId',
    };
  }
  final kind = storedKind?.trim();
  return {
    'id': id,
    'bookId': id,
    'title': id,
    if (kind != null && kind.isNotEmpty) 'kind': kind,
  };
}
