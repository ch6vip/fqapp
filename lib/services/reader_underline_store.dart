import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

/// One locally saved 划线: a paragraph the reader marked, kept on the device.
@immutable
class ReaderUnderline {
  final String bookId;
  final String chapterId;

  /// Upstream paragraph id, when the source carried one.
  final int? paraIndex;

  /// Ordinal of the paragraph inside the chapter, used when [paraIndex] is
  /// absent (`idx`-less content, e.g. a plain-text cache).
  final int blockIndex;

  final String text;
  final int createdAt;

  const ReaderUnderline({
    required this.bookId,
    required this.chapterId,
    required this.blockIndex,
    required this.text,
    this.paraIndex,
    this.createdAt = 0,
  });

  /// See [paragraphUnderlineId].
  int get id => paragraphUnderlineId(
    paraIndex: paraIndex,
    blockIndex: blockIndex,
  );

  String get key => ReaderUnderlineStore.keyFor(
    bookId: bookId,
    chapterId: chapterId,
    paraIndex: paraIndex,
    blockIndex: blockIndex,
  );

  Map<String, dynamic> toMap() => {
    'bookId': bookId,
    'chapterId': chapterId,
    if (paraIndex != null) 'paraIndex': paraIndex,
    'blockIndex': blockIndex,
    'text': text,
    'createdAt': createdAt,
  };

  static ReaderUnderline? fromMap(dynamic raw) {
    if (raw is! Map) return null;
    final bookId = raw['bookId'];
    final chapterId = raw['chapterId'];
    final text = raw['text'];
    final blockIndex = raw['blockIndex'];
    if (bookId is! String ||
        bookId.isEmpty ||
        chapterId is! String ||
        chapterId.isEmpty ||
        text is! String ||
        text.trim().isEmpty ||
        blockIndex is! num) {
      return null;
    }
    final paraIndex = raw['paraIndex'];
    final createdAt = raw['createdAt'];
    return ReaderUnderline(
      bookId: bookId,
      chapterId: chapterId,
      blockIndex: blockIndex.toInt(),
      text: text,
      paraIndex: paraIndex is num ? paraIndex.toInt() : null,
      createdAt: createdAt is num && createdAt.isFinite ? createdAt.toInt() : 0,
    );
  }
}

/// Identity of one paragraph inside a chapter, for 划线 and the paragraph menu.
///
/// The upstream `idx` wins whenever the markup carries one. Plenty of chapters
/// do not: `/api/content` answers with plain text, and that path stores no ids
/// at all. Those paragraphs are still editable, so they fall back to their
/// display ordinal, negated to keep the two namespaces from colliding.
int paragraphUnderlineId({int? paraIndex, required int blockIndex}) =>
    paraIndex ?? -(blockIndex + 1);

/// One locally saved 划线 over a character range inside one chapter — the
/// selection-model counterpart of [ReaderUnderline], which marks whole
/// paragraphs. Both shapes share the same Hive box; [ReaderUnderline.fromMap]
/// rejects range maps (no `blockIndex`) and vice versa, so the two never
/// collide while scanning.
@immutable
class ReaderRangeUnderline {
  final String bookId;
  final String chapterId;

  /// Offsets into the chapter's display text — the same space as
  /// `ReaderContentBlock.start`, see [ReaderUnderlineStore.rangeKeyFor].
  final int start;
  final int end;
  final String text;
  final int createdAt;

  const ReaderRangeUnderline({
    required this.bookId,
    required this.chapterId,
    required this.start,
    required this.end,
    required this.text,
    this.createdAt = 0,
  });

  bool get isEmpty => end <= start;

  /// True when this record marks exactly [start]..[end] — the 删除划线 state.
  bool coversExactly(int start, int end) =>
      this.start == start && this.end == end;

  /// True when the selection sits entirely inside this mark, so removing it
  /// cannot cut through an unrelated underline.
  bool contains(int start, int end) =>
      this.start <= start && end <= this.end;

  String get key => ReaderUnderlineStore.rangeKeyFor(
    bookId: bookId,
    chapterId: chapterId,
    start: start,
    end: end,
  );

  Map<String, dynamic> toMap() => {
    'bookId': bookId,
    'chapterId': chapterId,
    'start': start,
    'end': end,
    'text': text,
    'createdAt': createdAt,
  };

  static ReaderRangeUnderline? fromMap(dynamic raw) {
    if (raw is! Map) return null;
    final bookId = raw['bookId'];
    final chapterId = raw['chapterId'];
    final text = raw['text'];
    final start = raw['start'];
    final end = raw['end'];
    if (bookId is! String ||
        bookId.isEmpty ||
        chapterId is! String ||
        chapterId.isEmpty ||
        text is! String ||
        text.trim().isEmpty ||
        start is! num ||
        end is! num ||
        end <= start) {
      return null;
    }
    final createdAt = raw['createdAt'];
    return ReaderRangeUnderline(
      bookId: bookId,
      chapterId: chapterId,
      start: start.toInt(),
      end: end.toInt(),
      text: text,
      createdAt: createdAt is num && createdAt.isFinite ? createdAt.toInt() : 0,
    );
  }
}

/// Local 划线 storage.
/// The official client keeps these server-side per account; the backend has no such
/// endpoint, so this stays on the device. Identity is (book, chapter,
/// paragraph), and a paragraph's id wins over its ordinal because titles and
/// pictures can shift the ordinal between parses.
class ReaderUnderlineStore {
  ReaderUnderlineStore({HiveInterface? hive, this.maxEntries = 2000})
    : _hive = hive ?? Hive;

  static final ReaderUnderlineStore instance = ReaderUnderlineStore();
  static const _boxName = 'reader_underlines_v1';

  /// Set once Hive has a directory (app bootstrap). Widget tests that never
  /// call Hive.initFlutter() leave this false, so nothing touches a box that
  /// cannot be opened yet.
  static bool hiveReady = false;

  final HiveInterface _hive;
  final int maxEntries;
  final ValueNotifier<int> changes = ValueNotifier(0);

  Future<Box<dynamic>>? _opening;
  Future<void> _writes = Future<void>.value();

  static String keyFor({
    required String bookId,
    required String chapterId,
    int? paraIndex,
    required int blockIndex,
  }) => jsonEncode([
    bookId,
    chapterId,
    paraIndex ?? -1,
    paraIndex != null ? -1 : blockIndex,
  ]);

  /// Key space of [ReaderRangeUnderline]: the `r` tag keeps range keys apart
  /// from the 4-tuple paragraph keys above.
  static String rangeKeyFor({
    required String bookId,
    required String chapterId,
    required int start,
    required int end,
  }) => jsonEncode(['r', bookId, chapterId, start, end]);

  static int _createdAtOf(dynamic raw) =>
      ReaderUnderline.fromMap(raw)?.createdAt ??
      ReaderRangeUnderline.fromMap(raw)?.createdAt ??
      0;

  /// Opens the box, or null when storage is unavailable.
  ///
  /// Hive throws when it has no directory yet (a bare widget test, or a device
  /// where the data directory could not be created). A rejected open is not
  /// cached, so a later call can succeed once storage exists.
  Future<Box<dynamic>?> _box() async {
    if (!hiveReady) return null;
    try {
      // Hive throws synchronously when it has no directory yet, so the call
      // itself has to sit inside the guard, not only its await.
      final pending = _opening ??= _hive.openBox<dynamic>(_boxName);
      final box = await pending;
      if (box.isOpen) return box;
      _opening = null;
    } catch (_) {
      _opening = null;
      return null;
    }
    return _box();
  }

  Future<T> _serialize<T>(
    Future<T> Function(Box<dynamic>) action, {
    required T onUnavailable,
    bool failWhenUnavailable = false,
  }) {
    final operation = _writes.then((_) async {
      final box = await _box();
      if (box == null) {
        if (failWhenUnavailable) {
          throw StateError('划线存储不可用');
        }
        return onUnavailable;
      }
      return action(box);
    });
    _writes = operation.then<void>((_) {}, onError: (Object _) {});
    return operation;
  }

  /// Every saved underline of one chapter, keyed by [ReaderUnderline.key].
  Future<Map<String, ReaderUnderline>> load(String bookId, String chapterId) =>
      _serialize((box) async {
        final out = <String, ReaderUnderline>{};
        for (final raw in box.values) {
          final entry = ReaderUnderline.fromMap(raw);
          if (entry == null) continue;
          if (entry.bookId != bookId || entry.chapterId != chapterId) continue;
          out[entry.key] = entry;
        }
        return out;
      }, onUnavailable: const {});

  Future<void> add(ReaderUnderline underline) => _serialize(
    (box) async {
      await box.put(underline.key, underline.toMap());
      await _evictBeyondMax(box);
      changes.value++;
    },
    onUnavailable: null,
    failWhenUnavailable: true,
  );

  Future<void> addRange(ReaderRangeUnderline underline) => _serialize(
    (box) async {
      await box.put(underline.key, underline.toMap());
      await _evictBeyondMax(box);
      changes.value++;
    },
    onUnavailable: null,
    failWhenUnavailable: true,
  );

  /// A failed eviction must surface through the surrounding [_serialize]
  /// chain — a fire-and-forget [Box.deleteAll] escaped it as an unhandled
  /// async error, and the store would keep treating the cap as recovered.
  Future<void> _evictBeyondMax(Box<dynamic> box) async {
    if (box.length <= maxEntries) return;
    final oldest = box.keys.toList()
      ..sort(
        (a, b) => _createdAtOf(
          box.get(a),
        ).compareTo(_createdAtOf(box.get(b))),
      );
    await box.deleteAll(oldest.take(box.length - maxEntries));
  }

  /// Every saved range underline of one chapter, ordered by [start].
  Future<List<ReaderRangeUnderline>> loadRanges(
    String bookId,
    String chapterId,
  ) => _serialize((box) async {
    final out = <ReaderRangeUnderline>[];
    for (final raw in box.values) {
      final entry = ReaderRangeUnderline.fromMap(raw);
      if (entry == null) continue;
      if (entry.bookId != bookId || entry.chapterId != chapterId) continue;
      out.add(entry);
    }
    out.sort((a, b) => a.start.compareTo(b.start));
    return out;
  }, onUnavailable: const []);

  Future<void> remove(String key) => _serialize(
    (box) async {
      await box.delete(key);
      changes.value++;
    },
    onUnavailable: null,
    failWhenUnavailable: true,
  );

  Future<void> clearBook(String bookId) => _serialize((box) async {
    final doomed = <dynamic>[];
    for (final key in box.keys) {
      final raw = box.get(key);
      final book = ReaderUnderline.fromMap(raw)?.bookId ??
          ReaderRangeUnderline.fromMap(raw)?.bookId;
      if (book == bookId) doomed.add(key);
    }
    if (doomed.isNotEmpty) await box.deleteAll(doomed);
    changes.value++;
  }, onUnavailable: null);
}
