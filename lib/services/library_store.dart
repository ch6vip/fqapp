import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

abstract interface class ReaderStore {
  Future<Map<String, dynamic>?> historyEntry(String id);

  Future<void> addHistory(Map<String, dynamic> entry);

  Future<void> updateProgress(
    String id,
    int episode,
    double progress, {
    String? chapterId,
    double? position,
    double? maxScroll,
  });

  Future<void> accumulateReadTime(
    String bookId,
    String kind,
    double seconds, {
    DateTime? at,
  });
}

class LibraryStore implements ReaderStore {
  LibraryStore._();
  static final LibraryStore instance = LibraryStore._();

  static const _histBoxName = 'history';
  static const _readTimeBoxName = 'read_time';

  late Box<dynamic> _histBox;
  late Box<dynamic> _readTimeBox;
  Future<void> _readTimeWrites = Future<void>.value();

  /// Hive-backed notifications for retained tabs. Visible pages update after
  /// writes; hidden pages defer their snapshots until the next visit.
  ValueListenable<Box<dynamic>> get historyListenable => _histBox.listenable();
  ValueListenable<Box<dynamic>> get readTimeListenable =>
      _readTimeBox.listenable();

  Future<void> init() async {
    _histBox = await Hive.openBox(_histBoxName);
    _readTimeBox = await Hive.openBox(_readTimeBoxName);
    await _migrateFromSp();
  }

  Future<void> _migrateFromSp() async {
    final sp = await SharedPreferences.getInstance();

    // Retry incomplete migrations without overwriting newer Hive records.
    final history = sp.get('hist');
    if (history is String) {
      try {
        final decoded = jsonDecode(history);
        if (decoded is List) {
          for (final item in decoded.reversed) {
            final map = _historyRecord(item);
            if (map == null) continue;
            final id = map['id'] as String;
            if (!_histBox.containsKey(id)) await _histBox.put(id, map);
          }
          await sp.remove('hist');
        }
      } catch (_) {
        // Keep the source until all valid records have been written.
      }
    }

    final readTime = sp.get('read_time_map');
    if (readTime is String) {
      try {
        final decoded = jsonDecode(readTime);
        if (decoded is Map) {
          for (final entry in decoded.entries) {
            final id = entry.key.toString();
            if (id.isEmpty) continue;
            final days = _readTimeRecord(entry.value);
            if (days.isEmpty) continue;
            await _readTimeBox.put(id, {
              ...days,
              ..._readTimeRecord(_readTimeBox.get(id)),
            });
          }
          await sp.remove('read_time_map');
        }
      } catch (_) {
        // A later launch can finish a partially written migration.
      }
    }
  }

  List<Map<String, dynamic>> historySnapshot() {
    final values = <Map<String, dynamic>>[
      for (final key in _histBox.keys)
        ?_historyRecord(_histBox.get(key), id: key.toString()),
    ];
    // Sort by time descending (newest first)
    values.sort((a, b) {
      final ta = (a['time'] as num?)?.toInt() ?? 0;
      final tb = (b['time'] as num?)?.toInt() ?? 0;
      return tb.compareTo(ta);
    });
    return values;
  }

  Future<List<Map<String, dynamic>>> history() async => historySnapshot();

  @override
  Future<Map<String, dynamic>?> historyEntry(String id) async {
    final entry = _histBox.get(id);
    return _historyRecord(entry, id: id);
  }

  @override
  Future<void> addHistory(Map<String, dynamic> entry) async {
    final record = _historyRecord(entry);
    if (record == null) return;
    final id = record['id'] as String;

    await _histBox.put(id, record);

    // Trim history to 50 entries once it grows past 100 (leaves headroom so
    // we don't prune on every single write).
    if (_histBox.length > 100) {
      final keys = _histBox.keys.toList();
      int time(dynamic key) =>
          _historyRecord(_histBox.get(key), id: key.toString())?['time']
              as int? ??
          0;
      keys.sort((a, b) => time(a).compareTo(time(b)));
      final oldestKeys = keys.take(_histBox.length - 50);
      await _histBox.deleteAll(oldestKeys);
    }
  }

  @override
  Future<void> updateProgress(
    String id,
    int episode,
    double progress, {
    String? chapterId,
    double? position,
    double? maxScroll,
  }) async {
    final map = _historyRecord(_histBox.get(id), id: id);
    if (map != null) {
      map['episode'] = episode;
      map['progress'] = progress;
      if (chapterId != null) map['chapterId'] = chapterId;
      if (position != null) map['position'] = position;
      if (maxScroll != null) map['maxScroll'] = maxScroll;
      map['time'] = DateTime.now().millisecondsSinceEpoch;
      await _histBox.put(id, _historyRecord(map));
    }
  }

  Future<void> clearHistory() async {
    await _histBox.clear();
  }

  Map<String, Map<String, double>> readTimeSnapshot() {
    final out = <String, Map<String, double>>{};
    for (final key in _readTimeBox.keys) {
      final days = _readTimeRecord(_readTimeBox.get(key));
      if (days.isNotEmpty) out[key.toString()] = days;
    }
    return out;
  }

  Future<Map<String, Map<String, double>>> readTimeMap() async =>
      readTimeSnapshot();

  @override
  Future<void> accumulateReadTime(
    String bookId,
    String kind,
    double seconds, {
    DateTime? at,
  }) {
    if (!seconds.isFinite || seconds <= 0 || bookId.isEmpty) {
      return Future<void>.value();
    }
    final day = _dayKey(at ?? DateTime.now());
    final write = _readTimeWrites.then((_) async {
      final perBook = _readTimeRecord(_readTimeBox.get(bookId));
      perBook[day] = (perBook[day] ?? 0) + seconds;
      await _readTimeBox.put(bookId, perBook);
    });
    // Keep the serialization chain usable after an individual Hive error,
    // while still returning that error to the original caller.
    _readTimeWrites = write.catchError((_) {});
    return write;
  }

  static String _dayKey(DateTime d) => '${d.year}-${d.month}-${d.day}';

  static num? _finiteNumber(dynamic value) {
    final number = value is num
        ? value
        : value is String
        ? num.tryParse(value)
        : null;
    return number != null && number.isFinite ? number : null;
  }

  static Map<String, dynamic>? _historyRecord(dynamic raw, {String? id}) {
    if (raw is! Map) return null;
    final record = <String, dynamic>{
      for (final entry in raw.entries)
        if (entry.key is String) entry.key as String: entry.value,
    };
    final recordId = id ?? record['id']?.toString();
    if (recordId == null || recordId.isEmpty) return null;
    record['id'] = recordId;
    for (final key in [
      'time',
      'episode',
      'position',
      'maxScroll',
      'progress',
    ]) {
      final number = _finiteNumber(record[key]);
      if (number == null || number < 0) {
        record.remove(key);
      } else if (key == 'time') {
        // DateTime cannot represent timestamps beyond this range.
        record[key] = number <= 8640000000000000 ? number.toInt() : 0;
      } else if (key == 'episode') {
        record[key] = number.toInt();
      } else {
        record[key] = key == 'progress'
            ? number.clamp(0, 1).toDouble()
            : number.toDouble();
      }
    }
    return record;
  }

  static Map<String, double> _readTimeRecord(dynamic raw) {
    if (raw is! Map) return {};
    return {
      for (final entry in raw.entries)
        if (_finiteNumber(entry.value) case final seconds?)
          if (seconds >= 0) entry.key.toString(): seconds.toDouble(),
    };
  }
}
