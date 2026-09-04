import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/media_item.dart';

/// Local storage for favorites and reading/video history.
class LibraryStore {
  LibraryStore._();

  static final LibraryStore instance = LibraryStore._();

  static const _favsKey = 'favs';
  static const _histKey = 'hist';
  static const _readTimeKey = 'read_time_map';

  Future<List<MediaItem>> favorites() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_favsKey);
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .whereType<Map>()
          .map((e) => MediaItem.fromRaw(Map<String, dynamic>.from(e)))
          .where((item) => item.id.isNotEmpty)
          .toList();
    } catch (_) {
      // A partially written preference should not prevent the app from
      // starting. The next favorite write will replace it with valid JSON.
      return [];
    }
  }

  Future<void> toggleFavorite(MediaItem item) async {
    final sp = await SharedPreferences.getInstance();
    final favs = await favorites();
    final idx = favs.indexWhere((f) => f.id == item.id);
    if (idx >= 0) {
      favs.removeAt(idx);
    } else {
      favs.insert(0, item);
    }
    await sp.setString(
      _favsKey,
      jsonEncode(favs.map((f) => f.toJson()).toList()),
    );
  }

  Future<bool> isFavorite(String id) async {
    final favs = await favorites();
    return favs.any((f) => f.id == id);
  }

  Future<void> clearFavorites() async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_favsKey);
  }

  // ---- history ----
  Future<List<Map<String, dynamic>>> history() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_histKey);
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<Map<String, dynamic>?> historyEntry(String id) async {
    final entries = await history();
    for (final entry in entries) {
      if (entry['id']?.toString() == id) return entry;
    }
    return null;
  }

  Future<void> addHistory(Map<String, dynamic> entry) async {
    final sp = await SharedPreferences.getInstance();
    final h = await history();
    final entryId = entry['id']?.toString();
    h.removeWhere((e) => e['id']?.toString() == entryId);
    h.insert(0, entry);
    if (h.length > 50) h.removeRange(50, h.length);
    await sp.setString(_histKey, jsonEncode(h));
  }

  Future<void> updateProgress(
    String id,
    int episode,
    double progress, {
    String? chapterId,
    double? position,
    double? maxScroll,
  }) async {
    final sp = await SharedPreferences.getInstance();
    final h = await history();
    final i = h.indexWhere((e) => e['id']?.toString() == id);
    if (i >= 0) {
      h[i]['episode'] = episode;
      h[i]['progress'] = progress;
      if (chapterId != null) h[i]['chapterId'] = chapterId;
      if (position != null) h[i]['position'] = position;
      if (maxScroll != null) h[i]['maxScroll'] = maxScroll;
      h[i]['time'] = DateTime.now().millisecondsSinceEpoch;
      await sp.setString(_histKey, jsonEncode(h));
    }
  }

  Future<void> clearHistory() async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_histKey);
  }

  // ---- reading time (legado-style event-delta accumulation) ----
  //
  // Stores a nested map {bookId: {"2026-9-4": seconds}} under _readTimeKey.
  // Reader/player accumulate deltas at page changes / playback ticks and the
  // stats page aggregates by day (heatmap, daily records) or by book (rank).

  /// All recorded reading time: bookId → dayKey → seconds.
  Future<Map<String, Map<String, double>>> readTimeMap() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_readTimeKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final out = <String, Map<String, double>>{};
      decoded.forEach((bookId, value) {
        if (value is Map) {
          out[bookId] = value.map(
            (k, v) => MapEntry(k.toString(), (v as num).toDouble()),
          );
        }
      });
      return out;
    } catch (_) {
      return {};
    }
  }

  /// Adds [seconds] of reading time to [bookId] on the day of [at].
  Future<void> accumulateReadTime(
    String bookId,
    String kind,
    double seconds, {
    DateTime? at,
  }) async {
    if (seconds <= 0 || bookId.isEmpty) return;
    final sp = await SharedPreferences.getInstance();
    final map = await readTimeMap();
    final day = _dayKey(at ?? DateTime.now());
    final perBook = map[bookId] ?? {};
    perBook[day] = (perBook[day] ?? 0) + seconds;
    map[bookId] = perBook;
    await sp.setString(_readTimeKey, jsonEncode(map));
  }

  static String _dayKey(DateTime d) => '${d.year}-${d.month}-${d.day}';
}
