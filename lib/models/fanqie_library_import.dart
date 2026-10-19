/// Credential-free projection shared by Android import and the local converter.
/// Only explicit novel records enter the reader; audio/comic identities differ.
library;

import 'media_item.dart';

bool resolveFanqieChapter(Map<String, dynamic> record, List<Chapter> chapters) {
  final chapterId = record['chapterId'];
  if (chapterId == null) return false;
  final index = chapters.indexWhere((c) => c.itemId == chapterId);
  if (index < 0) return false;
  record['episode'] = index;
  record['progress'] = index / chapters.length;
  record['ep'] = '第 ${index + 1} 章';
  return true;
}

class FanqieLibraryImport {
  final Map<String, Map<String, dynamic>> _books = {};
  final Map<String, Map<String, dynamic>> _positions = {};
  int received = 0;
  int failed = 0;
  int skipped = 0;

  void addSource(Map<String, dynamic> source) {
    if (source['status'] != 'received') {
      failed++;
      return;
    }
    received++;
    final payload = source['payload'];
    if (payload is! Map || !const [0, '0'].contains(payload['code'])) return;
    final resource = source['resource'];
    final data = payload['data'];
    if (resource == 'book_detail') {
      if (data is Map) _metadata(data);
      return;
    }
    if (resource == 'history' && data is Map) {
      for (final raw in data['data_list'] as List? ?? const []) {
        if (raw is! Map) continue;
        if (!_novel(raw) || raw['is_delete'] == true || raw['is_delete'] == 1) {
          skipped++;
          continue;
        }
        final record = _include(raw);
        if (record == null) continue;
        final time = _time(raw);
        if (time > (record['time'] as int)) record['time'] = time;
      }
    } else if (resource == 'shelf_list' ||
        resource == 'shelf_info' ||
        resource == 'folder_detail') {
      void visit(dynamic value) {
        if (value is List) {
          for (final item in value) {
            visit(item);
          }
        } else if (value is Map) {
          if (_novel(value)) {
            // A book record's nested maps/lists are its own fields
            // (author info, nested recommendations), not more shelf
            // entries. Recursing into them would import recommendations
            // and related books as if the user had shelved them.
            _include(value);
            return;
          }
          for (final child in value.values) {
            if (child is Map || child is List) visit(child);
          }
        }
      }

      visit(data);
    } else if ((resource == 'progress_list' || resource == 'progress_batch') &&
        data is List) {
      for (final raw in data) {
        if (raw is! Map || !_novel(raw)) continue;
        final record = _include(raw);
        final chapter = _id(raw['item_id']);
        if (record == null || chapter == null) continue;
        final id = record['id'] as String;
        final time = _time(raw);
        final previous = _positions[id];
        if (previous != null && time < (previous['time'] as int)) continue;
        _positions[id] = {
          'time': time,
          'chapterId': chapter,
          // Preserve evidence, never reinterpret paragraph offsets as UTF-16.
          'officialAnchor': {
            for (final key in [
              'order',
              'real_chapter_order',
              'paragraph_id',
              'paragraph_offset',
              'item_progress_rate',
              'progress_rate',
            ])
              if (raw[key] is num || raw[key] is String) key: raw[key],
          },
        };
      }
    }
  }

  bool _novel(Map raw) => raw['book_type']?.toString() == '0';

  Map<String, dynamic>? _include(Map raw) {
    final id = _id(raw['book_id_str']) ?? _id(raw['book_id']);
    if (id == null) return null;
    final record = _books.putIfAbsent(
      id,
      () => {
        'id': id,
        'bookId': id,
        'kind': 'book',
        'title': '',
        'cover': '',
        'author': '',
        'time': 0,
        'fanqieImported': true,
      },
    );
    _fill(record, raw);
    return record;
  }

  void _metadata(Map raw) {
    final id = _id(raw['book_id']);
    // Metadata alone is not proof of a shelf/history relationship.
    if (id == null) return;
    final record = _books[id];
    if (record != null) _fill(record, raw);
  }

  void _fill(Map<String, dynamic> record, Map raw) {
    for (final field in {
      'title': 'book_name',
      'cover': 'thumb_url',
      'author': 'author',
    }.entries) {
      final value = raw[field.value];
      if (value is String && value.isNotEmpty && value.length <= 8192) {
        if (field.key == 'cover') {
          final uri = Uri.tryParse(value);
          if (uri == null ||
              !const ['http', 'https'].contains(uri.scheme) ||
              uri.host.isEmpty ||
              uri.userInfo.isNotEmpty) {
            continue;
          }
        }
        record[field.key] = value;
      }
    }
  }

  List<Map<String, dynamic>> get records => [
    for (final entry in _books.entries)
      {
        ...entry.value,
        if (_positions[entry.key] case final position?) ...{
          'chapterId': position['chapterId'],
          'officialAnchor': position['officialAnchor'],
          'time': (entry.value['time'] as int) > (position['time'] as int)
              ? entry.value['time']
              : position['time'],
        },
      },
  ];

  static int _time(Map raw) {
    final ms = int.tryParse('${raw['read_timestamp_ms']}') ?? 0;
    final seconds = int.tryParse('${raw['read_timestamp']}') ?? 0;
    final time = ms > 0 ? ms : seconds * 1000;
    return time >= 0 && time <= 8640000000000000 ? time : 0;
  }

  static String? _id(dynamic value) {
    final text = value?.toString() ?? '';
    return RegExp(r'^[0-9]{1,20}$').hasMatch(text) &&
            !RegExp(r'^0+$').hasMatch(text)
        ? text
        : null;
  }
}
