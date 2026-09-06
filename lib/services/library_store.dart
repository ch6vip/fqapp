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

    // Migrate history
    if (sp.containsKey('hist') && _histBox.isEmpty) {
      final raw = sp.getString('hist');
      if (raw != null) {
        try {
          final list = jsonDecode(raw) as List;
          for (final item in list.reversed) {
            // reversed to maintain insertion order
            final map = Map<String, dynamic>.from(item);
            final id = map['id']?.toString() ?? '';
            if (id.isNotEmpty) {
              await _histBox.put(id, map);
            }
          }
        } catch (_) {}
      }
      await sp.remove('hist');
    }

    // Migrate read time
    if (sp.containsKey('read_time_map') && _readTimeBox.isEmpty) {
      final raw = sp.getString('read_time_map');
      if (raw != null) {
        try {
          final map = jsonDecode(raw) as Map<String, dynamic>;
          for (final entry in map.entries) {
            await _readTimeBox.put(entry.key, entry.value);
          }
        } catch (_) {}
      }
      await sp.remove('read_time_map');
    }
  }

  List<Map<String, dynamic>> historySnapshot() {
    final values = _histBox.values.toList();
    // Sort by time descending (newest first)
    values.sort((a, b) {
      final ta = (a['time'] as num?)?.toInt() ?? 0;
      final tb = (b['time'] as num?)?.toInt() ?? 0;
      return tb.compareTo(ta);
    });
    return values.map((e) => Map<String, dynamic>.from(e)).toList();
  }

  Future<List<Map<String, dynamic>>> history() async => historySnapshot();

  @override
  Future<Map<String, dynamic>?> historyEntry(String id) async {
    final entry = _histBox.get(id);
    return entry != null ? Map<String, dynamic>.from(entry) : null;
  }

  @override
  Future<void> addHistory(Map<String, dynamic> entry) async {
    final id = entry['id']?.toString();
    if (id == null) return;

    await _histBox.put(id, entry);

    // Trim history to 50 entries once it grows past 100 (leaves headroom so
    // we don't prune on every single write).
    if (_histBox.length > 100) {
      final values = _histBox.values.toList();
      values.sort((a, b) {
        final ta = (a['time'] as num?)?.toInt() ?? 0;
        final tb = (b['time'] as num?)?.toInt() ?? 0;
        return ta.compareTo(tb); // oldest first
      });
      final oldestKeys = values
          .take(_histBox.length - 50)
          .map((e) => e['id']?.toString());
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
    final h = _histBox.get(id);
    if (h != null) {
      final map = Map<String, dynamic>.from(h);
      map['episode'] = episode;
      map['progress'] = progress;
      if (chapterId != null) map['chapterId'] = chapterId;
      if (position != null) map['position'] = position;
      if (maxScroll != null) map['maxScroll'] = maxScroll;
      map['time'] = DateTime.now().millisecondsSinceEpoch;
      await _histBox.put(id, map);
    }
  }

  Future<void> clearHistory() async {
    await _histBox.clear();
  }

  Map<String, Map<String, double>> readTimeSnapshot() {
    final out = <String, Map<String, double>>{};
    for (final key in _readTimeBox.keys) {
      final value = _readTimeBox.get(key);
      if (value is Map) {
        out[key.toString()] = value.map(
          (k, v) => MapEntry(k.toString(), (v as num).toDouble()),
        );
      }
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
    if (seconds <= 0 || bookId.isEmpty) return Future<void>.value();
    final day = _dayKey(at ?? DateTime.now());
    final write = _readTimeWrites.then((_) async {
      final existingMap = _readTimeBox.get(bookId);
      final perBook = existingMap != null
          ? Map<String, dynamic>.from(existingMap)
          : <String, dynamic>{};
      perBook[day] = ((perBook[day] as num?)?.toDouble() ?? 0) + seconds;
      await _readTimeBox.put(bookId, perBook);
    });
    // Keep the serialization chain usable after an individual Hive error,
    // while still returning that error to the original caller.
    _readTimeWrites = write.catchError((_) {});
    return write;
  }

  static String _dayKey(DateTime d) => '${d.year}-${d.month}-${d.day}';
}
