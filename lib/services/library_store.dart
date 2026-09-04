import 'dart:convert';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/media_item.dart';

class LibraryStore {
  LibraryStore._();
  static final LibraryStore instance = LibraryStore._();

  static const _favsBoxName = 'favorites';
  static const _histBoxName = 'history';
  static const _readTimeBoxName = 'read_time';

  late Box _favsBox;
  late Box _histBox;
  late Box _readTimeBox;

  Future<void> init() async {
    _favsBox = await Hive.openBox(_favsBoxName);
    _histBox = await Hive.openBox(_histBoxName);
    _readTimeBox = await Hive.openBox(_readTimeBoxName);
    await _migrateFromSp();
  }

  Future<void> _migrateFromSp() async {
    final sp = await SharedPreferences.getInstance();
    
    // Migrate favs
    if (sp.containsKey('favs') && _favsBox.isEmpty) {
      final raw = sp.getString('favs');
      if (raw != null) {
        try {
          final list = jsonDecode(raw) as List;
          for (final item in list) {
            final map = Map<String, dynamic>.from(item);
            final id = map['id']?.toString() ?? '';
            if (id.isNotEmpty) {
              await _favsBox.put(id, map);
            }
          }
        } catch (_) {}
      }
      await sp.remove('favs');
    }

    // Migrate history
    if (sp.containsKey('hist') && _histBox.isEmpty) {
      final raw = sp.getString('hist');
      if (raw != null) {
        try {
          final list = jsonDecode(raw) as List;
          for (final item in list.reversed) { // reversed to maintain insertion order
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

  Future<List<MediaItem>> favorites() async {
    final values = _favsBox.values.toList();
    // Hive boxes iterate by key, not insertion order. Sort by the stored
    // favorite timestamp so the shelf keeps "most recently added first".
    values.sort((a, b) {
      final ta = (a['favTime'] as num?)?.toInt() ?? 0;
      final tb = (b['favTime'] as num?)?.toInt() ?? 0;
      return tb.compareTo(ta);
    });
    return values
        .map((e) => MediaItem.fromRaw(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<void> toggleFavorite(MediaItem item) async {
    if (_favsBox.containsKey(item.id)) {
      await _favsBox.delete(item.id);
    } else {
      final json = item.toJson()..['favTime'] = DateTime.now().millisecondsSinceEpoch;
      await _favsBox.put(item.id, json);
    }
  }

  Future<bool> isFavorite(String id) async {
    return _favsBox.containsKey(id);
  }

  Future<void> clearFavorites() async {
    await _favsBox.clear();
  }

  Future<List<Map<String, dynamic>>> history() async {
    final values = _histBox.values.toList();
    // Sort by time descending (newest first)
    values.sort((a, b) {
      final ta = (a['time'] as num?)?.toInt() ?? 0;
      final tb = (b['time'] as num?)?.toInt() ?? 0;
      return tb.compareTo(ta);
    });
    return values.map((e) => Map<String, dynamic>.from(e)).toList();
  }

  Future<Map<String, dynamic>?> historyEntry(String id) async {
    final entry = _histBox.get(id);
    return entry != null ? Map<String, dynamic>.from(entry) : null;
  }

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
      final oldestKeys = values.take(_histBox.length - 50).map((e) => e['id']?.toString());
      await _histBox.deleteAll(oldestKeys);
    }
  }

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

  Future<Map<String, Map<String, double>>> readTimeMap() async {
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

  Future<void> accumulateReadTime(
    String bookId,
    String kind,
    double seconds, {
    DateTime? at,
  }) async {
    if (seconds <= 0 || bookId.isEmpty) return;
    final day = _dayKey(at ?? DateTime.now());
    
    final existingMap = _readTimeBox.get(bookId);
    final perBook = existingMap != null ? Map<String, dynamic>.from(existingMap) : <String, dynamic>{};
    
    perBook[day] = ((perBook[day] as num?)?.toDouble() ?? 0) + seconds;
    await _readTimeBox.put(bookId, perBook);
  }

  static String _dayKey(DateTime d) => '${d.year}-${d.month}-${d.day}';
}
