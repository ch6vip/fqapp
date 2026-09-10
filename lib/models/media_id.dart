import 'media_item.dart';

final _numericId = RegExp(r'^[0-9]{1,20}$');
final _longId = RegExp(r'^[0-9]{15,20}$');
final _explicitId = RegExp(r'^id\s*[:：]\s*(.*)$', caseSensitive: false);

/// Short numeric titles such as "1984" stay keyword searches. The explicit
/// prefix also permits shorter IDs and lets the lookup report invalid input.
String? mediaIdFromSearch(String query) {
  final value = query.trim();
  final explicit = _explicitId.firstMatch(value);
  if (explicit != null) return explicit.group(1)!.trim();
  return _longId.hasMatch(value) ? value : null;
}

bool isValidMediaId(String id) =>
    _numericId.hasMatch(id) && id.contains(RegExp(r'[1-9]'));

/// Only an exact work identity with a real title is a lookup result. Traverse
/// metadata wrappers, never recommendations or individual directory chapters.
MediaItem? parseMediaIdResult(Map<String, dynamic> payload, String id) {
  MediaItem? visit(dynamic value, int depth) {
    if (depth > 5) return null;
    if (value is List) {
      for (final entry in value) {
        final item = visit(entry, depth + 1);
        if (item != null) return item;
      }
      return null;
    }
    if (value is! Map) return null;
    final raw = Map<String, dynamic>.from(value);
    final code = raw['code'];
    if ((code != null && code != 0 && code != 200) || raw['success'] == false) {
      return null;
    }
    final hasTitle = ['title', 'book_name', 'name', 'raw_book_name'].any((key) {
      final title = raw[key];
      return title is String && title.trim().isNotEmpty ||
          title is Map &&
              title['text'] is String &&
              (title['text'] as String).trim().isNotEmpty;
    });
    if (hasTitle) {
      var item = MediaItem.fromRaw(raw);
      // Detail and directory metadata identify the whole drama by book_id;
      // make that series identity explicit for the existing player/history.
      if (isVideoKind(item.kind) &&
          item.seriesId == null &&
          raw['book_id']?.toString() == id) {
        item = MediaItem.fromRaw({...raw, 'series_id': id});
      }
      if (item.id == id) return item;
    }
    for (final key in ['book_info', 'book_data', 'data']) {
      final item = visit(raw[key], depth + 1);
      if (item != null) return item;
    }
    return null;
  }

  return visit(payload, 0);
}
