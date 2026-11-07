import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive.dart';

import 'encrypted_hive.dart';

/// A local reading location, independent of underlines and shelf membership.
@immutable
class ReaderBookmark {
  const ReaderBookmark({
    required this.bookId,
    required this.chapterId,
    required this.title,
    required this.text,
    required this.sourceOffset,
    required this.createdAt,
  });

  final String bookId;
  final String chapterId;
  final String title;
  final String text;

  /// Offset into the untransformed source chapter, not its current display.
  final int sourceOffset;
  final int createdAt;

  String get key => jsonEncode([bookId, chapterId, sourceOffset]);

  Map<String, dynamic> toMap() => {
    'bookId': bookId,
    'chapterId': chapterId,
    'title': title,
    'text': text,
    'sourceOffset': sourceOffset,
    'createdAt': createdAt,
  };

  static int? _nonnegativeInteger(dynamic value) {
    if (value is! num || !value.isFinite || value < 0) return null;
    final integer = value.toInt();
    return integer == value ? integer : null;
  }

  static ReaderBookmark? fromMap(dynamic raw) {
    if (raw is! Map) return null;
    final bookId = raw['bookId'];
    final chapterId = raw['chapterId'];
    final title = raw['title'];
    final text = raw['text'];
    final sourceOffset = _nonnegativeInteger(raw['sourceOffset']);
    final createdAt = _nonnegativeInteger(raw['createdAt']);
    if (bookId is! String ||
        bookId.trim().isEmpty ||
        chapterId is! String ||
        chapterId.trim().isEmpty ||
        title is! String ||
        text is! String ||
        sourceOffset == null ||
        createdAt == null) {
      return null;
    }
    return ReaderBookmark(
      bookId: bookId,
      chapterId: chapterId,
      title: title,
      text: text,
      sourceOffset: sourceOffset,
      createdAt: createdAt,
    );
  }
}

/// Device-only bookmarks. Reads join the write queue so a reload always sees
/// preceding saves/deletions. Failed operations do not poison subsequent work.
class ReaderBookmarkStore {
  ReaderBookmarkStore({HiveInterface? hive, this.maxEntries = 2000})
    : _hive = hive ?? Hive {
    if (maxEntries < 1) {
      throw ArgumentError.value(maxEntries, 'maxEntries', 'must be positive');
    }
  }

  static final ReaderBookmarkStore instance = ReaderBookmarkStore();
  static bool hiveReady = false;
  static const _boxName = 'reader_bookmarks_v1';

  final HiveInterface _hive;
  final int maxEntries;
  final ValueNotifier<int> changes = ValueNotifier(0);
  Future<Box<dynamic>>? _opening;
  Future<void> _writes = Future<void>.value();

  Future<Box<dynamic>> _box() async {
    if (!hiveReady) throw StateError('书签存储尚未就绪');
    try {
      final box = await (_opening ??= EncryptedHive.openBox<dynamic>(
        _hive,
        _boxName,
      ));
      if (box.isOpen) return box;
      _opening = null;
      final reopened = await (_opening = EncryptedHive.openBox<dynamic>(
        _hive,
        _boxName,
      ));
      if (!reopened.isOpen) throw StateError('书签存储已关闭');
      return reopened;
    } catch (_) {
      _opening = null;
      rethrow;
    }
  }

  Future<T> _serialize<T>(Future<T> Function(Box<dynamic>) action) {
    final operation = _writes.then((_) async => action(await _box()));
    _writes = operation.then<void>((_) {}, onError: (Object _) {});
    return operation;
  }

  Future<List<ReaderBookmark>> loadBook(String bookId) => _serialize((
    box,
  ) async {
    final records = <ReaderBookmark>[];
    for (final raw in box.values) {
      final record = ReaderBookmark.fromMap(raw);
      if (record == null) {
        // Preserve corrupt data for recovery; do not present it as an empty box.
        throw const FormatException('书签记录无法读取');
      }
      if (record.bookId == bookId) records.add(record);
    }
    records.sort((a, b) {
      final order = b.createdAt.compareTo(a.createdAt);
      return order == 0 ? a.key.compareTo(b.key) : order;
    });
    return List.unmodifiable(records);
  });

  Future<void> add(ReaderBookmark record) => _serialize((box) async {
    if (ReaderBookmark.fromMap(record.toMap()) == null) {
      throw const FormatException('书签位置无效');
    }
    if (!box.containsKey(record.key) && box.length >= maxEntries) {
      throw StateError('书签已达 $maxEntries 条上限，请先删除不需要的书签');
    }
    await box.put(record.key, record.toMap());
    changes.value++;
  });

  Future<void> remove(String key) => _serialize((box) async {
    if (!box.containsKey(key)) return;
    await box.delete(key);
    changes.value++;
  });
}
