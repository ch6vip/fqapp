import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/media_item.dart';

/// Local storage for favorites and reading/video history.
class LibraryStore {
  LibraryStore._();

  static final LibraryStore instance = LibraryStore._();

  static const _favsKey = 'favs';
  static const _histKey = 'hist';

  Future<List<MediaItem>> favorites() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_favsKey);
    if (raw == null) return [];
    final list = jsonDecode(raw) as List;
    return list
        .map((e) => MediaItem.fromRaw(Map<String, dynamic>.from(e as Map)))
        .toList();
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
        _favsKey, jsonEncode(favs.map((f) => f.toJson()).toList()));
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
    final list = jsonDecode(raw) as List;
    return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<void> addHistory(Map<String, dynamic> entry) async {
    final sp = await SharedPreferences.getInstance();
    final h = await history();
    h.removeWhere((e) => e['id'] == entry['id']);
    h.insert(0, entry);
    if (h.length > 50) h.removeRange(50, h.length);
    await sp.setString(_histKey, jsonEncode(h));
  }

  Future<void> updateProgress(String id, int episode, double progress) async {
    final sp = await SharedPreferences.getInstance();
    final h = await history();
    final i = h.indexWhere((e) => e['id'] == id);
    if (i >= 0) {
      h[i]['episode'] = episode;
      h[i]['progress'] = progress;
      h[i]['time'] = DateTime.now().millisecondsSinceEpoch;
      await sp.setString(_histKey, jsonEncode(h));
    }
  }

  Future<void> clearHistory() async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_histKey);
  }
}

extension MediaItemJson on MediaItem {
  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'cover': cover,
        'author': author,
        'badge': badge,
        'ep': ep,
        'kind': kind,
      };
}
