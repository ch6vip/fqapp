import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive.dart';

import '../models/media_item.dart';
import '../models/shelf_identity.dart';
import '../models/shuqi_book.dart';
import 'encrypted_hive.dart';

/// One 加入书架 record.
class ShelfRecord {
  final MediaItem item;
  final DateTime addedAt;

  const ShelfRecord({required this.item, required this.addedAt});
}

/// The device-local 加入书架 collection.
///
/// The official client keeps this on the account: the shelf's 书架 tab lists
/// the favourites that sync across devices, and short dramas reach it through
/// 追剧. The backend has no favourites endpoint and this app has no login, so the
/// shelf is a Hive box next to the reading history instead. Records carry the
/// same fields the history does, so one set of cards renders both.
///
/// Note: 官方把「加入书架 / 追剧」存在账号上，这里退化为本地集合；理由与被否掉的
/// 方案见 .agents/notes/implemented/feature/2026-09-20-official-bookshelf.md
class ShelfStore {
  ShelfStore._();

  static final ShelfStore instance = ShelfStore._();

  static const boxName = 'shelf';

  Box<dynamic>? _box;
  final ValueNotifier<int> _revision = ValueNotifier<int>(0);

  /// Bumps on every write; the shelf page rebuilds from it.
  ValueListenable<int> get listenable => _revision;

  bool get isReady => _openBox != null;

  /// The box, but only while it is usable. A closed box (Hive.close() between
  /// test cases, a failed reopen) reads as "no local shelf" instead of throwing
  /// out of every card on the page.
  Box<dynamic>? get _openBox {
    final box = _box;
    return box != null && box.isOpen ? box : null;
  }

  /// The stable key of one shelf entry. The series id wins over the item id for
  /// the same reason the detail page prefers it: a short drama can be opened
  /// from a single episode and must still land on the series.
  ///
  /// The source is part of the identity: a 书旗 book shares numeric ids with
  /// 番茄 books, and without the prefix one would look like the other. The
  /// fanqie prefix is omitted so every existing record keeps its exact key.
  static String keyFor(String kind, String id, {String source = 'fanqie'}) =>
      ShelfIdentity.storageKeyFor(kind, id, source: source);

  static String keyOf(MediaItem item) => ShelfIdentity.storageKeyOf(item);

  /// The source-qualified identity without the `shelf_v1:` storage prefix.
  static String contentKeyOf(MediaItem item) =>
      ShelfIdentity.contentKeyOf(item);

  Future<void> init() async {
    if (_openBox != null) return;
    final box = await EncryptedHive.openBox<dynamic>(Hive, boxName);
    await _migrateShuqiReaderEntries(box);
    _box = box;
    _revision.value++;
  }

  Future<void> _migrateShuqiReaderEntries(Box<dynamic> box) async {
    final readerId = RegExp(r'^shuqi:([0-9]+)$');
    final additions = <String, dynamic>{};
    final oldKeys = <String>[];
    for (final key in box.keys) {
      final raw = box.get(key);
      if (key is! String || raw is! Map || raw['kind'] != 'book') continue;
      final id = raw['id'];
      if (id is! String || key != keyFor('book', id)) continue;
      final bookId = readerId.firstMatch(id)?.group(1);
      if (bookId == null || !ShelfIdentity.isValidContentId(bookId)) continue;
      if ((raw['source'] != null && raw['source'] != ShelfIdentity.fanqie) ||
          raw['seriesId'] != null ||
          raw['episodeId'] != null) {
        continue;
      }
      final target = keyFor('book', bookId, source: shuqiSourceId);
      if (box.containsKey(target)) {
        final existing = box.get(target);
        final item = existing is Map
            ? _itemFrom(existing, storageKey: target)
            : null;
        if (item == null ||
            item.id != bookId ||
            item.kind != 'book' ||
            !isShuqiItem(item) ||
            item.seriesId != null ||
            item.episodeId != null) {
          continue;
        }
      } else {
        additions[target] = {...raw, 'id': bookId, 'source': shuqiSourceId};
      }
      oldKeys.add(key);
    }
    if (oldKeys.isNotEmpty) {
      // Older readers saved their session ID as a fanqie shelf entry (#270).
      // Keep addedAt and any canonical record; flush before removing old keys
      // so an interrupted migration can retry without losing the book.
      if (additions.isNotEmpty) await box.putAll(additions);
      await box.flush();
      await box.deleteAll(oldKeys);
    }
    await box.flush();
  }

  bool contains(String kind, String id, {String source = 'fanqie'}) {
    final value = _openBox?.get(keyFor(kind, id, source: source));
    return value is Map;
  }

  bool containsItem(MediaItem item) =>
      _openBox?.containsKey(keyOf(item)) ?? false;

  /// Newest first. Callers that need the official ordering (置顶 → 最近阅读)
  /// sort further; this is only the storage order.
  List<ShelfRecord> records() {
    final box = _openBox;
    if (box == null) return const [];
    final records = <ShelfRecord>[];
    for (final key in box.keys) {
      final raw = box.get(key);
      if (raw is! Map) continue;
      // The storage key carries the source prefix for non-fanqie records;
      // passing it through lets a legacy record that never wrote `source`
      // heal its source instead of being read as a 番茄 book.
      final item = _itemFrom(raw, storageKey: key.toString());
      if (item == null) continue;
      records.add(
        ShelfRecord(item: item, addedAt: _addedAt(raw) ?? DateTime(1970)),
      );
    }
    records.sort((a, b) => b.addedAt.compareTo(a.addedAt));
    return records;
  }

  /// Adds the item, or removes it when it is already on the shelf.
  /// Returns true when the item is on the shelf afterwards.
  Future<bool> toggle(MediaItem item) async {
    final box = _openBox;
    if (box == null) return false;
    final key = keyOf(item);
    if (box.containsKey(key)) {
      await box.delete(key);
      _revision.value++;
      return false;
    }
    await box.put(key, _recordOf(item, DateTime.now()));
    _revision.value++;
    return true;
  }

  Future<void> add(MediaItem item) async {
    final box = _openBox;
    if (box == null) return;
    await box.put(keyOf(item), _recordOf(item, DateTime.now()));
    _revision.value++;
  }

  Future<void> removeKeys(Iterable<String> keys) async {
    final box = _openBox;
    if (box == null) return;
    final known = keys.toSet();
    if (known.isEmpty) return;
    await box.deleteAll(known.where(box.containsKey));
    _revision.value++;
  }

  /// 撤销「移出书架」：把记录按**原 addedAt** 写回（`_recordOf` 含 addedAt
  /// 字段，schema 不变）。页面在移出前把选中的 [ShelfRecord] 暂存在内存
  /// 闭包里，SnackBar 撤销时调这里恢复。
  ///
  /// 仅内存级：进程死亡即失效，诚实不做伪恢复。
  Future<void> restoreAll(Iterable<ShelfRecord> records) async {
    final box = _openBox;
    if (box == null) return;
    var wrote = false;
    for (final record in records) {
      await box.put(keyOf(record.item), _recordOf(record.item, record.addedAt));
      wrote = true;
    }
    if (wrote) _revision.value++;
  }

  Future<void> clear() async {
    final box = _openBox;
    if (box == null) return;
    await box.clear();
    _revision.value++;
  }

  /// The check and putAll are synchronous up to the first await, so another
  /// shelf action cannot slip between the check and Hive's in-memory update.
  Future<int> mergeBackup(Iterable<ShelfRecord> records) async {
    final box = _openBox;
    if (box == null) throw StateError('书架尚未初始化');
    final missing = {
      for (final record in records)
        if (!box.containsKey(keyOf(record.item)))
          keyOf(record.item): _recordOf(record.item, record.addedAt),
    };
    if (missing.isEmpty) {
      // A retry after a failed flush must still retry durable persistence.
      await box.flush();
      return 0;
    }
    try {
      await box.putAll(missing);
      await box.flush();
    } finally {
      // A failed disk write can still have changed part of the visible box.
      _revision.value++;
    }
    return missing.length;
  }

  /// Apply a remote shelf only where it still matches the snapshot taken
  /// before networking. A tap made during the request keeps its local result.
  Future<void> applySyncedShelf({
    required List<ShelfRecord> before,
    required List<ShelfRecord> incoming,
  }) async {
    final box = _openBox;
    if (box == null) throw StateError('书架尚未初始化');
    final expected = {for (final entry in before) keyOf(entry.item): entry};
    final target = {for (final entry in incoming) keyOf(entry.item): entry};
    bool unchanged(String key) {
      final raw = box.get(key);
      final old = expected[key];
      return old == null
          ? raw == null
          : raw is Map && _addedAt(raw) == old.addedAt;
    }

    final deleted = expected.keys
        .where((key) => !target.containsKey(key) && unchanged(key))
        .toList();
    final writes = {
      for (final entry in target.entries)
        if (unchanged(entry.key))
          entry.key: _recordOf(entry.value.item, entry.value.addedAt),
    };
    // Both Hive mutations enter memory before yielding; UI edits afterwards
    // are later writes and will be picked up by the next sync.
    final deleting = box.deleteAll(deleted);
    final writing = box.putAll(writes);
    try {
      await Future.wait([deleting, writing]);
      await box.flush();
    } finally {
      _revision.value++;
    }
  }

  /// Reuses the same shelf keys and card model. Enrich existing cards while
  /// preserving the user's local shelf ordering and collection membership.
  Future<int> mergeFanqie(Iterable<ShelfRecord> records) async {
    final box = _openBox;
    if (box == null) throw StateError('书架尚未初始化');
    var changed = 0;
    try {
      for (final record in records) {
        final key = keyOf(record.item);
        final old = box.get(key);
        final next = _recordOf(record.item, record.addedAt);
        if (old is Map) {
          next['addedAt'] = old['addedAt'];
          for (final field in ['title', 'cover', 'author', 'badge', 'ep']) {
            if (next[field] == '' && old[field] is String) {
              next[field] = old[field];
            }
          }
        }
        await box.put(key, next);
        changed++;
      }
      await box.flush();
    } finally {
      _revision.value++;
    }
    return changed;
  }

  static Map<String, dynamic> _recordOf(MediaItem item, DateTime addedAt) => {
    'id': item.id,
    'kind': item.kind,
    'title': item.title,
    'cover': item.cover,
    'author': item.author,
    'badge': item.badge,
    'ep': item.ep,
    // 番茄是默认来源，省略字段让旧记录形状保持不变。
    if (item.source != 'fanqie') 'source': item.source,
    if (item.intro.isNotEmpty) 'intro': item.intro,
    if (item.categories.isNotEmpty) 'categories': item.categories,
    if (item.creationStatus >= 0) 'creationStatus': item.creationStatus,
    if (item.wordNumber > 0) 'wordNumber': item.wordNumber,
    'seriesId': item.seriesId,
    'episodeId': item.episodeId,
    'addedAt': addedAt.millisecondsSinceEpoch,
  };

  static DateTime? _addedAt(Map<dynamic, dynamic> raw) {
    final value = raw['addedAt'];
    return value is num && value > 0
        ? DateTime.fromMillisecondsSinceEpoch(value.toInt())
        : null;
  }

  /// A broken record must not take the whole shelf down with it: unknown shapes
  /// are skipped, which is the same rule the history list follows.
  ///
  /// The source is resolved in three steps: an explicit valid `source` field,
  /// then the source prefix of the storage key (self-healing for records
  /// written before that field existed), then fanqie.
  static MediaItem? _itemFrom(Map<dynamic, dynamic> raw, {String? storageKey}) {
    final id = raw['id']?.toString() ?? '';
    final title = raw['title']?.toString() ?? '';
    if (id.isEmpty && title.isEmpty) return null;
    final recordedSource = raw['source']?.toString() ?? '';
    final source =
        recordedSource.isNotEmpty && ShelfIdentity.isValidSource(recordedSource)
        ? recordedSource
        : _sourceFromStorageKey(storageKey);
    return MediaItem(
      id: id,
      title: title.isEmpty ? '未知作品' : title,
      cover: raw['cover']?.toString() ?? '',
      author: raw['author']?.toString() ?? '',
      badge: raw['badge']?.toString() ?? '',
      ep: raw['ep']?.toString() ?? '',
      kind: raw['kind']?.toString() ?? 'book',
      source: source,
      intro: raw['intro']?.toString() ?? '',
      categories: [
        if (raw['categories'] is List)
          for (final value in raw['categories'] as List)
            if (value is String && value.isNotEmpty) value,
      ],
      creationStatus: raw['creationStatus'] is num
          ? (raw['creationStatus'] as num).toInt()
          : -1,
      wordNumber: raw['wordNumber'] is num
          ? (raw['wordNumber'] as num).toInt()
          : 0,
      seriesId: raw['seriesId']?.toString(),
      episodeId: raw['episodeId']?.toString(),
    );
  }

  static String _sourceFromStorageKey(String? storageKey) {
    if (storageKey == null) return 'fanqie';
    final contentKey = storageKey.startsWith(ShelfIdentity.storagePrefix)
        ? storageKey.substring(ShelfIdentity.storagePrefix.length)
        : storageKey;
    return ShelfIdentity.parseContentKey(contentKey)?.source ?? 'fanqie';
  }
}
