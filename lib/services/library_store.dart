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
  static const _legacyTimeKey = '_legacy_media_time_v1';
  static const _newTimeKey = '_new_media_time_v1';
  static const _kindKey = '_media_kind_v1';

  late Box<dynamic> _histBox;
  late Box<dynamic> _readTimeBox;
  Future<void> _readTimeWrites = Future<void>.value();
  Future<void> _historyWrites = Future<void>.value();

  /// Hive-backed notifications for retained tabs. Visible pages update after
  /// writes; hidden pages defer their snapshots until the next visit.
  ValueListenable<Box<dynamic>> get historyListenable => _histBox.listenable();
  ValueListenable<Box<dynamic>> get readTimeListenable =>
      _readTimeBox.listenable();

  Future<void> init() async {
    _histBox = await Hive.openBox(_histBoxName);
    _readTimeBox = await Hive.openBox(_readTimeBoxName);
    await _migrateFromSp();
    // Copy typed legacy media before a novel can reuse its original key.
    // The originals remain available if a write fails or migration is retried.
    for (final key in _histBox.keys.toList()) {
      final record = _historyRecord(_histBox.get(key), id: key.toString());
      if (record == null) continue;
      try {
        await _preserveLegacyMedia(record);
      } catch (_) {
        // Saving that media or replacing its key retries the preservation.
      }
    }
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
            final current = _readTimeStorage(_readTimeBox.get(id));
            final savedDays = _readTimeRecord(current);
            final newDays = _newReadTime(current);
            for (final day in days.entries) {
              final newSeconds = newDays[day.key] ?? 0;
              final oldSeconds = (savedDays[day.key] ?? 0) - newSeconds;
              if (day.value > oldSeconds) {
                // A retry may backfill old seconds on a day that already has
                // new reading time. Keep both without importing the old twice.
                current[day.key] = day.value + newSeconds;
              }
            }
            await _readTimeBox.put(id, current);
          }
          await sp.remove('read_time_map');
        }
      } catch (_) {
        // A later launch can finish a partially written migration.
      }
    }
  }

  List<Map<String, dynamic>> historySnapshot() {
    final byIdentity = <(String, String), Map<String, dynamic>>{};
    for (final key in _histBox.keys) {
      final record = _historyRecord(_histBox.get(key), id: key.toString());
      if (record == null) continue;
      final identity = _historyIdentity(record);
      final previous = byIdentity[identity];
      final scoped = record['contentId'] != null;
      final previousScoped = previous?['contentId'] != null;
      final time = (record['time'] as num?) ?? 0;
      final previousTime = (previous?['time'] as num?) ?? 0;
      if (previous == null ||
          (scoped && !previousScoped) ||
          (scoped == previousScoped && time > previousTime)) {
        byIdentity[identity] = record;
      }
    }
    final values = byIdentity.values.toList();
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
  Future<void> addHistory(Map<String, dynamic> entry) {
    // Serialize history mutations so a clear cannot overtake a pending write.
    final write = _historyWrites.then((_) => _addHistoryInWrite(entry));
    _historyWrites = write.catchError((Object _) {});
    return write;
  }

  Future<void> _addHistoryInWrite(Map<String, dynamic> entry) async {
    final record = _historyRecord(entry);
    if (record == null) return;
    final id = record['id'] as String;

    final originalId = record['contentId']?.toString() ?? id;
    final previous = _historyRecord(_histBox.get(originalId), id: originalId);
    if (previous != null &&
        (record['contentId'] != null || previous['kind'] != record['kind'])) {
      await _preserveLegacyMedia(previous);
    }

    await _histBox.put(id, record);

    // Trim history to 50 entries once it grows past 100 (leaves headroom so
    // we don't prune on every single write).
    if (_histBox.length > 100) {
      // Legacy backups must not make fifty books look like a hundred books.
      final retained = historySnapshot().take(50).map(_historyIdentity).toSet()
        // Never trim the record this write just inserted, even without a time.
        ..add(_historyIdentity(record));
      final oldestKeys = <dynamic>[];
      for (final key in _histBox.keys) {
        final record = _historyRecord(_histBox.get(key), id: key.toString());
        if (record == null || !retained.contains(_historyIdentity(record))) {
          oldestKeys.add(key);
        }
      }
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
    // Partial novel updates cannot establish their kind after a failed insert.
    // Scoped media first copies its legacy record, then updates the scoped key.
    if (map != null && _legacyMediaKey(map) == null) {
      map['episode'] = episode;
      map['progress'] = progress;
      if (chapterId != null) map['chapterId'] = chapterId;
      if (position != null) map['position'] = position;
      if (maxScroll != null) map['maxScroll'] = maxScroll;
      map['time'] = DateTime.now().millisecondsSinceEpoch;
      await _histBox.put(id, _historyRecord(map));
    }
  }

  Future<void> clearHistory() {
    // Enqueue after any pending history write so the clear is durable.
    final write = _historyWrites.then<void>((_) async {
      await _histBox.clear();
    });
    _historyWrites = write.catchError((Object _) {});
    return write;
  }

  /// Removes saved history together with the per-day reading/playback time
  /// shown on the statistics page.
  Future<void> clearReadingData() {
    final write = _historyWrites.then<void>((_) async {
      await _readTimeWrites;
      await _histBox.clear();
      await _readTimeBox.clear();
    });
    _historyWrites = write.catchError((Object _) {});
    return write;
  }

  Map<String, Map<String, double>> readTimeSnapshot() {
    final out = <String, Map<String, double>>{};
    for (final key in _readTimeBox.keys) {
      final days = _readTimeRecord(_readTimeBox.get(key));
      if (days.isNotEmpty) out[key.toString()] = days;
    }

    // A saved baseline assigns old seconds to their media without deleting
    // the original data. Future novel seconds at the original ID remain its
    // own time, and retrying migration never adds the baseline twice.
    for (final key in _readTimeBox.keys) {
      final allocation = _legacyTimeAllocation(_readTimeBox.get(key));
      if (allocation == null) continue;
      final (sourceId, days) = allocation;
      _addDays(out, key.toString(), days);
      _subtractDays(out[sourceId], days);
      if (out[sourceId]?.isEmpty ?? false) out.remove(sourceId);
    }

    // Records written by an older version can exist before init's migration
    // or before their first save. Normalize their statistics immediately.
    for (final key in _histBox.keys) {
      final record = _historyRecord(_histBox.get(key), id: key.toString());
      if (record == null) continue;
      final target = _legacyMediaKey(record);
      if (target == null) continue;
      final id = record['id'] as String;
      final remaining = out[id];
      if (remaining == null) continue;
      final days = Map<String, double>.from(remaining);
      _subtractDays(days, _newReadTime(_readTimeBox.get(id)));
      _addDays(out, target, days);
      _subtractDays(remaining, days);
      if (remaining.isEmpty) out.remove(id);
    }
    return out;
  }

  Future<Map<String, Map<String, double>>> readTimeMap() async =>
      readTimeSnapshot();

  /// The media kind recorded with each read-time identity, when known. Used by
  /// statistics to open read-time-only rows with the right content type.
  Map<String, String> readTimeKindSnapshot() {
    final out = <String, String>{};
    for (final key in _readTimeBox.keys) {
      final raw = _readTimeBox.get(key);
      final kind = raw is Map ? raw[_kindKey] : null;
      if (kind is String && kind.trim().isNotEmpty) {
        out[key.toString()] = kind.trim();
      }
    }
    return out;
  }

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
      final history = _historyRecord(_histBox.get(bookId), id: bookId);
      final legacy = history != null && _legacyMediaKey(history) != null;
      final newTime = !legacy || history['kind'] != kind;
      if (legacy && newTime) {
        // This callback already owns the queue. Preserve directly so a failed
        // history insert cannot make new novel seconds part of the old media.
        await _preserveLegacyMediaInWrite(history);
      }
      final raw = _readTimeBox.get(bookId);
      final perBook = _readTimeStorage(raw);
      final days = _readTimeRecord(raw);
      perBook[day] = (days[day] ?? 0) + seconds;
      final kindLabel = kind.trim();
      if (kindLabel.isNotEmpty) perBook[_kindKey] = kindLabel;
      if (newTime) {
        final newDays = _newReadTime(raw);
        newDays[day] = (newDays[day] ?? 0) + seconds;
        // Persist the counter and its classification atomically.
        perBook[_newTimeKey] = newDays;
      }
      await _readTimeBox.put(bookId, perBook);
    });
    // Keep the serialization chain usable after an individual Hive error,
    // while still returning that error to the original caller.
    _readTimeWrites = write.catchError((_) {});
    return write;
  }

  static (String, String) _historyIdentity(Map<String, dynamic> record) => (
    record['kind']?.toString() ?? 'book',
    (record['contentId'] ?? record['id']).toString(),
  );

  static String? _legacyMediaKey(Map<String, dynamic> record) {
    final kind = record['kind'];
    if (record['contentId'] != null || (kind != 'audio' && kind != 'manga')) {
      return null;
    }
    return '$kind:${record['id']}';
  }

  Future<void> _preserveLegacyMedia(Map<String, dynamic> record) {
    if (_legacyMediaKey(record) == null) return Future<void>.value();
    final write = _readTimeWrites.then(
      (_) => _preserveLegacyMediaInWrite(record),
    );
    _readTimeWrites = write.catchError((Object _) {});
    return write;
  }

  Future<void> _preserveLegacyMediaInWrite(Map<String, dynamic> record) async {
    final target = _legacyMediaKey(record);
    if (target == null) return;
    final id = record['id'] as String;
    if (!_histBox.containsKey(target)) {
      await _histBox.put(target, {...record, 'id': target, 'contentId': id});
    }
    final current = _readTimeBox.get(target);
    final previous = _legacyTimeAllocation(current);
    final source = _readTimeBox.get(id);
    final days = _readTimeRecord(source);
    _subtractDays(days, _newReadTime(source));
    // A retry can find both an existing allocation and newly migrated days.
    // Add only old seconds that have not already been assigned to any media.
    for (final key in _readTimeBox.keys) {
      final allocation = _legacyTimeAllocation(_readTimeBox.get(key));
      if (allocation != null && allocation.$1 == id) {
        _subtractDays(days, allocation.$2);
      }
    }
    final allocated = previous?.$1 == id ? previous!.$2 : <String, double>{};
    for (final day in days.entries) {
      allocated[day.key] = (allocated[day.key] ?? 0) + day.value;
    }
    await _readTimeBox.put(target, {
      ..._readTimeStorage(current),
      _legacyTimeKey: {'sourceId': id, 'days': allocated},
    });
  }

  static (String, Map<String, double>)? _legacyTimeAllocation(dynamic raw) {
    if (raw is! Map) return null;
    final value = raw[_legacyTimeKey];
    if (value is! Map ||
        value['sourceId'] is! String ||
        value['days'] is! Map) {
      return null;
    }
    final id = value['sourceId'] as String;
    return id.isEmpty ? null : (id, _readTimeRecord(value['days']));
  }

  static Map<String, dynamic> _readTimeStorage(dynamic raw) => {
    ..._readTimeRecord(raw),
    if (raw is Map && raw[_legacyTimeKey] is Map)
      _legacyTimeKey: raw[_legacyTimeKey],
    if (raw is Map && raw[_newTimeKey] is Map) _newTimeKey: raw[_newTimeKey],
    if (raw is Map && raw[_kindKey] is String) _kindKey: raw[_kindKey],
  };

  static Map<String, double> _newReadTime(dynamic raw) =>
      raw is Map ? _readTimeRecord(raw[_newTimeKey]) : {};

  static void _addDays(
    Map<String, Map<String, double>> totals,
    String id,
    Map<String, double> days,
  ) {
    if (days.isEmpty) return;
    final target = totals.putIfAbsent(id, () => <String, double>{});
    for (final day in days.entries) {
      target[day.key] = (target[day.key] ?? 0) + day.value;
    }
  }

  static void _subtractDays(
    Map<String, double>? target,
    Map<String, double> days,
  ) {
    if (target == null) return;
    for (final day in days.entries) {
      final remaining = (target[day.key] ?? 0) - day.value;
      if (remaining > 0) {
        target[day.key] = remaining;
      } else {
        target.remove(day.key);
      }
    }
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
        // The stored media-kind is metadata, not a day counter; a numeric
        // String kind must never be parsed into a fake reading day.
        if (entry.key != _kindKey)
          if (_finiteNumber(entry.value) case final seconds?)
            if (seconds >= 0) entry.key.toString(): seconds.toDouble(),
    };
  }
}
