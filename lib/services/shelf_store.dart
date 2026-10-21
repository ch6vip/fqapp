import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive.dart';

import '../models/media_item.dart';

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
  static const _keyPrefix = 'shelf_v1:';

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
  static String keyFor(String kind, String id) => '$_keyPrefix$kind:$id';

  static String keyOf(MediaItem item) =>
      keyFor(item.kind, item.seriesId ?? item.id);

  Future<void> init() async {
    if (_openBox != null) return;
    _box = await Hive.openBox<dynamic>(boxName);
    _revision.value++;
  }

  bool contains(String kind, String id) {
    final value = _openBox?.get(keyFor(kind, id));
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
      final item = _itemFrom(raw);
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
  static MediaItem? _itemFrom(Map<dynamic, dynamic> raw) {
    final id = raw['id']?.toString() ?? '';
    final title = raw['title']?.toString() ?? '';
    if (id.isEmpty && title.isEmpty) return null;
    return MediaItem(
      id: id,
      title: title.isEmpty ? '未知作品' : title,
      cover: raw['cover']?.toString() ?? '',
      author: raw['author']?.toString() ?? '',
      badge: raw['badge']?.toString() ?? '',
      ep: raw['ep']?.toString() ?? '',
      kind: raw['kind']?.toString() ?? 'book',
      seriesId: raw['seriesId']?.toString(),
      episodeId: raw['episodeId']?.toString(),
    );
  }
}
