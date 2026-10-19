import 'dart:convert';
import 'dart:typed_data';

import 'library_backup.dart';

/// Only the confirmed read-history fields are carried into local storage.
class FanqieHistoryPage {
  final List<Map<String, dynamic>> records;
  final bool hasMore;
  final int nextOffset;
  final int oldestTimestamp;
  final int sourceCount;

  /// Records dropped because they were malformed (not a map, or missing a
  /// usable book id / timestamp). They are skipped, never fatal: one dirty
  /// record must not block the whole page's history import.
  final int skipped;

  const FanqieHistoryPage(
    this.records,
    this.hasMore,
    this.nextOffset,
    this.oldestTimestamp,
    this.sourceCount, {
    this.skipped = 0,
  });

  factory FanqieHistoryPage.parse(Map<String, dynamic> envelope) {
    if (envelope['code'] != 0 && envelope['code'] != '0') {
      throw const FormatException('番茄未返回成功结果，请重新登录后重试');
    }
    final data = envelope['data'];
    if (data is! Map ||
        data['data_list'] is! List ||
        data['has_more'] is! bool) {
      throw const FormatException('番茄历史响应格式不兼容');
    }
    final items = data['data_list'] as List;
    if (items.length > 10000) throw const FormatException('历史记录超过上限');
    final offset = _integer(data['next_offset']);
    if (offset == null || offset < 0) {
      throw const FormatException('历史分页游标无效');
    }
    final records = <Map<String, dynamic>>[];
    var oldest = 0;
    var skipped = 0;
    for (final raw in items) {
      // A single malformed record skips itself; it never aborts the page.
      if (raw is! Map) {
        skipped++;
        continue;
      }
      final time = _integer(raw['read_timestamp_ms']);
      if (time != null && time > 0 && (oldest == 0 || time < oldest)) {
        oldest = time;
      }
      if (raw['is_delete'] == true || raw['is_delete'] == 1) continue;
      if (_integer(raw['book_type']) != 0) continue;
      final id = _id(raw['book_id_str']) ?? _id(raw['book_id']);
      if (id == null || time == null || time < 0 || time > 8640000000000000) {
        skipped++;
        continue;
      }
      records.add({
        'id': id,
        'bookId': id,
        'kind': 'book',
        // Title/cover are display-only: a malformed one blanks the field
        // instead of dropping a record whose id and time are valid.
        'title': _text(raw['book_name']),
        'cover': _text(raw['thumb_url']),
        'time': time,
        // chapter_index has no verified base or chapter-ID mapping yet.
        // Leaving position absent is safer than opening a wrong chapter.
      });
    }
    return FanqieHistoryPage(
      records,
      data['has_more'] as bool,
      offset,
      oldest,
      items.length,
      skipped: skipped,
    );
  }

  static int? _integer(dynamic value) => value is int
      ? value
      : value is String
      ? int.tryParse(value)
      : null;

  static String? _id(dynamic value) {
    final text = value is int
        ? value.toString()
        : value is String
        ? value
        : '';
    return RegExp(r'^[0-9]{1,24}$').hasMatch(text) ? text : null;
  }

  static String _text(dynamic value) {
    if (value == null) return '';
    if (value is! String || value.length > 8192) return '';
    return value;
  }
}

class FanqieHistoryPreview {
  final LibraryBackup validated;
  final int sourceCount;
  final int duplicateCount;
  final int skipped;

  const FanqieHistoryPreview._(
    this.validated,
    this.sourceCount,
    this.duplicateCount, {
    this.skipped = 0,
  });

  factory FanqieHistoryPreview.fromRecords(
    List<Map<String, dynamic>> records,
    int sourceCount, {
    int skipped = 0,
  }) {
    final unique = <String, Map<String, dynamic>>{};
    for (final record in records) {
      final id = record['id'] as String;
      final previous = unique[id];
      if (previous == null ||
          (record['time'] as int) > (previous['time'] as int)) {
        unique[id] = record;
      }
    }
    return FanqieHistoryPreview._(
      LibraryBackup.capture(
        shelf: [],
        history: unique.values.toList(),
        watched: {},
      ),
      sourceCount,
      records.length - unique.length,
      skipped: skipped,
    );
  }

  factory FanqieHistoryPreview.fromBytes(Uint8List bytes) {
    if (bytes.length > LibraryBackup.maxBytes) {
      throw const FormatException('历史文件超过 16 MB');
    }
    dynamic raw;
    try {
      raw = jsonDecode(utf8.decode(bytes).replaceFirst(RegExp(r'^\uFEFF'), ''));
    } on FormatException {
      throw const FormatException('文件不是有效的 UTF-8 JSON');
    }
    if (raw is! Map<String, dynamic>) {
      throw const FormatException('请选择官方 read_history 接口 JSON 响应');
    }
    final page = FanqieHistoryPage.parse(raw);
    if (page.hasMore) {
      throw const FormatException('该响应还有下一页，请先获取完整历史，避免误以为已导入全部');
    }
    return FanqieHistoryPreview.fromRecords(
      page.records,
      page.sourceCount,
      skipped: page.skipped,
    );
  }
}
