import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'reader_underline_store.dart';

abstract interface class ReaderStore {
  Future<Map<String, dynamic>?> historyEntry(String id);

  Future<void> addHistory(Map<String, dynamic> entry);

  Future<void> updateProgress(
    String id,
    int episode,
    double progress, {
    String? chapterId,
    double? position,
    double? maxScroll,
  });

  Future<void> accumulateReadTime(
    String bookId,
    String kind,
    double seconds, {
    DateTime? at,
  });

  /// 已看集的稳定标识集合（**剧集/视频 id**，不是下标）。
  /// 官方用 `VideoGlobalManager.b(seriesId).c(vid)` 判「这一集看过」
  /// （`hj3/r0.java:445`），键就是 vid。
  Future<Set<String>> watchedEpisodeIds(String id);

  /// 标记若干集为已看（按 id 并集写入）。
  Future<void> markEpisodeWatched(String id, Iterable<String> episodeIds);

  /// 删除该剧的观看记录时一并清掉已看集合。
  Future<void> forgetWatchedEpisodes(String id);
}

/// Captures the clear boundary before a history wrapper waits for older saves.
/// History and statistics have separate generations because clearing history
/// intentionally leaves reading time intact.
/// See .agents/notes/implemented/bug-fix/2026-09-16-cross-review-boundaries.md.
class ReadingDataWriteGuard {
  static final _generations = Expando<_ReadingDataGeneration>(
    'reading data clear generations',
  );

  static _ReadingDataGeneration _forStore(ReaderStore store) =>
      _generations[store] ??= _ReadingDataGeneration();

  /// Scoped media writes share the underlying store's clear boundary.
  static void shareScope(ReaderStore scope, ReaderStore store) {
    _generations[scope] = _forStore(store);
  }

  ReadingDataWriteGuard(ReaderStore store) : this._(_forStore(store));

  ReadingDataWriteGuard._(this._generation)
    : _history = _generation.history,
      _readTime = _generation.readTime;

  final _ReadingDataGeneration _generation;
  final int _history;
  final int _readTime;

  bool get canWriteHistory => _history == _generation.history;
  bool get canWriteReadTime => _readTime == _generation.readTime;
}

class _ReadingDataGeneration {
  int history = 0;
  int readTime = 0;
}

class LibraryStore implements ReaderStore {
  LibraryStore._();
  static final LibraryStore instance = LibraryStore._();

  static const _histBoxName = 'history';
  static const _readTimeBoxName = 'read_time';
  /// 已看集（按剧集/视频 id）。官方把「这一集看过」存在
  /// `video_progress` 一族 SP 里、以 vid 为键（`com/dragon/read/video/d.java:18-20`
  /// 的 `video_progress` / `video_progress_time` / `video_newly_update_vids`），
  /// 本地同样**按 id 存**、与续播位置分开，避免列表重排后用下标串集。
  static const _watchedBoxName = 'watched_episodes';
  static const _legacyTimeKey = '_legacy_media_time_v1';
  static const _allocatedTimeKey = '_allocated_media_time_v1';
  static const _newTimeKey = '_new_media_time_v1';
  static const _kindKey = '_media_kind_v1';
  static const _touchedKey = '_last_touched_v1';

  /// Most recent day buckets kept per read-time identity. Older days are
  /// dropped, so a long-lived install cannot grow without bound.
  @visibleForTesting
  int readTimeRetentionDays = 730;

  /// Upper bound on retained read-time identities, evicted least-recently
  /// touched first.
  @visibleForTesting
  int maxReadTimeIdentities = 5000;

  late Box<dynamic> _histBox;
  late Box<dynamic> _readTimeBox;
  late Box<dynamic> _watchedBox;
  Future<void> _writes = Future<void>.value();

  Future<void> _serialize(Future<void> Function() action) {
    final write = _writes.then<void>((_) => action());
    // Return a failure to its caller without poisoning subsequent mutations.
    _writes = write.catchError((Object _) {});
    return write;
  }

  /// 与 [_serialize] 同一条队列，但把结果返回给调用方（删除要报条数）。
  Future<T> _serializeResult<T>(Future<T> Function() action) {
    final write = _writes.then<T>((_) => action());
    _writes = write.then<void>((_) {}).catchError((Object _) {});
    return write;
  }

  /// Hive-backed notifications for retained tabs. Visible pages update after
  /// writes; hidden pages defer their snapshots until the next visit.
  bool get isInitialized => Hive.isBoxOpen(_histBoxName);
  ValueListenable<Box<dynamic>> get historyListenable => _histBox.listenable();
  ValueListenable<Box<dynamic>> get readTimeListenable =>
      _readTimeBox.listenable();

  Future<void> init() async {
    _histBox = await Hive.openBox(_histBoxName);
    _readTimeBox = await Hive.openBox(_readTimeBoxName);
    _watchedBox = await Hive.openBox(_watchedBoxName);
    // Hive has a directory now, so optional boxes may be opened too.
    ReaderUnderlineStore.hiveReady = true;
    await _migrateFromSp();
    // Copy typed legacy media before a novel can reuse its original key.
    // The originals remain available if a write fails or migration is retried.
    for (final key in _histBox.keys.toList()) {
      final record = _historyRecord(_histBox.get(key), id: key.toString());
      if (record == null) continue;
      try {
        await _preserveLegacyMedia(record);
      } catch (_) {
        // Saving that media or replacing its key retries the preservation.
      }
    }
    // Upgrade path: bound records written before retention existed, and enforce
    // the identity cap on an already oversized box.
    await _sweepReadTime();
  }

  /// Prunes every over-limit read-time record at startup and enforces the
  /// identity cap. Records already within the limits are left untouched.
  Future<void> _sweepReadTime() async {
    final updated = <dynamic, dynamic>{};
    final empty = <dynamic>[];
    for (final key in _readTimeBox.keys) {
      final raw = _readTimeBox.get(key);
      if (raw is! Map || !_hasReadTimeData(raw)) {
        empty.add(key);
        continue;
      }
      if (!_readTimeNeedsPrune(raw)) continue;
      final record = _readTimeStorage(raw);
      _pruneRecordDays(record);
      updated[key] = record;
    }
    if (updated.isNotEmpty) await _readTimeBox.putAll(updated);
    if (empty.isNotEmpty) await _readTimeBox.deleteAll(empty);
    await _trimReadTimeIdentities();
  }

  static bool _hasReadTimeData(dynamic raw) {
    if (raw is! Map) return false;
    if (_readTimeRecord(raw).isNotEmpty) return true;
    final newDays = raw[_newTimeKey];
    if (newDays is Map && _readTimeRecord(newDays).isNotEmpty) return true;
    final legacy = raw[_legacyTimeKey];
    if (legacy is Map && _visibleLegacyDays(raw).isNotEmpty) {
      return true;
    }
    return false;
  }

  bool _readTimeNeedsPrune(Map<dynamic, dynamic> raw) {
    final own = _datedCount(raw);
    if (own > readTimeRetentionDays) return true;
    final newDays = raw[_newTimeKey];
    if (newDays is Map && _datedCount(newDays) > readTimeRetentionDays) {
      return true;
    }
    final allocated = raw[_allocatedTimeKey];
    if (allocated is Map && _datedCount(allocated) > readTimeRetentionDays) {
      return true;
    }
    final legacy = raw[_legacyTimeKey];
    if (legacy is Map) {
      final days = legacy['days'];
      if (days is Map && _datedCount(days) > readTimeRetentionDays) return true;
      final discarded = legacy['discardedDays'];
      if (discarded is Map && _datedCount(discarded) > readTimeRetentionDays) {
        return true;
      }
    }
    return false;
  }

  static int _datedCount(dynamic raw) {
    var count = 0;
    for (final entry in _readTimeRecord(raw).entries) {
      if (_parseDayKey(entry.key) != null) count++;
    }
    return count;
  }

  Future<void> _migrateFromSp() async {
    final sp = await SharedPreferences.getInstance();

    // Retry incomplete migrations without overwriting newer Hive records.
    final history = sp.get('hist');
    if (history is String) {
      try {
        final decoded = jsonDecode(history);
        if (decoded is List) {
          for (final item in decoded.reversed) {
            final map = _historyRecord(item);
            if (map == null) continue;
            final id = map['id'] as String;
            if (!_histBox.containsKey(id)) await _histBox.put(id, map);
          }
          await sp.remove('hist');
        }
      } catch (_) {
        // Keep the source until all valid records have been written.
      }
    }

    final readTime = sp.get('read_time_map');
    if (readTime is String) {
      try {
        final decoded = jsonDecode(readTime);
        if (decoded is Map) {
          for (final entry in decoded.entries) {
            final id = entry.key.toString();
            if (id.isEmpty) continue;
            final days = _readTimeRecord(entry.value);
            if (days.isEmpty) continue;
            final current = _readTimeStorage(_readTimeBox.get(id));
            final savedDays = _readTimeRecord(current);
            final newDays = _newReadTime(current);
            for (final day in days.entries) {
              final newSeconds = newDays[day.key] ?? 0;
              final oldSeconds = (savedDays[day.key] ?? 0) - newSeconds;
              if (day.value > oldSeconds) {
                // A retry may backfill old seconds on a day that already has
                // new reading time. Keep both without importing the old twice.
                current[day.key] = day.value + newSeconds;
              }
            }
            current[_touchedKey] = DateTime.now().millisecondsSinceEpoch;
            _pruneRecordDays(current);
            await _readTimeBox.put(id, current);
          }
          await _trimReadTimeIdentities();
          await sp.remove('read_time_map');
        }
      } catch (_) {
        // A later launch can finish a partially written migration.
      }
    }
  }

  List<Map<String, dynamic>> historySnapshot() {
    final byIdentity = <(String, String), Map<String, dynamic>>{};
    for (final key in _histBox.keys) {
      final record = _historyRecord(_histBox.get(key), id: key.toString());
      if (record == null) continue;
      final identity = _historyIdentity(record);
      final previous = byIdentity[identity];
      final scoped = record['contentId'] != null;
      final previousScoped = previous?['contentId'] != null;
      final time = (record['time'] as num?) ?? 0;
      final previousTime = (previous?['time'] as num?) ?? 0;
      if (previous == null ||
          (scoped && !previousScoped) ||
          (scoped == previousScoped && time > previousTime)) {
        byIdentity[identity] = record;
      }
    }
    final values = byIdentity.values.toList();
    // Sort by time descending (newest first)
    values.sort((a, b) {
      final ta = (a['time'] as num?)?.toInt() ?? 0;
      final tb = (b['time'] as num?)?.toInt() ?? 0;
      return tb.compareTo(ta);
    });
    return values;
  }

  Future<List<Map<String, dynamic>>> history() async => historySnapshot();

  @override
  Future<Map<String, dynamic>?> historyEntry(String id) async {
    final entry = _histBox.get(id);
    return _historyRecord(entry, id: id);
  }

  @override
  Future<void> addHistory(Map<String, dynamic> entry) {
    return _serialize(() => _addHistoryInWrite(entry));
  }

  Future<void> _addHistoryInWrite(Map<String, dynamic> entry) async {
    final record = _historyRecord(entry);
    if (record == null) return;
    final id = record['id'] as String;

    final originalId = record['contentId']?.toString() ?? id;
    final previous = _historyRecord(_histBox.get(originalId), id: originalId);
    if (previous != null &&
        (record['contentId'] != null || previous['kind'] != record['kind'])) {
      await _preserveLegacyMediaInWrite(previous);
    }

    await _histBox.put(id, record);

    // Trim history to 50 entries once it grows past 100 (leaves headroom so
    // we don't prune on every single write).
    if (_histBox.length > 100) {
      // Legacy backups must not make fifty books look like a hundred books.
      final retained = historySnapshot().take(50).map(_historyIdentity).toSet()
        // Never trim the record this write just inserted, even without a time.
        ..add(_historyIdentity(record));
      final oldestKeys = <dynamic>[];
      for (final key in _histBox.keys) {
        final record = _historyRecord(_histBox.get(key), id: key.toString());
        if (record == null || !retained.contains(_historyIdentity(record))) {
          oldestKeys.add(key);
        }
      }
      await _histBox.deleteAll(oldestKeys);
    }
  }

  @override
  Future<void> updateProgress(
    String id,
    int episode,
    double progress, {
    String? chapterId,
    double? position,
    double? maxScroll,
  }) => _serialize(() async {
    final map = _historyRecord(_histBox.get(id), id: id);
    // Partial novel updates cannot establish their kind after a failed insert.
    // Scoped media first copies its legacy record, then updates the scoped key.
    if (map != null && _legacyMediaKey(map) == null) {
      map['episode'] = episode;
      map['progress'] = progress;
      if (chapterId != null) map['chapterId'] = chapterId;
      if (position != null) map['position'] = position;
      if (maxScroll != null) map['maxScroll'] = maxScroll;
      map['time'] = DateTime.now().millisecondsSinceEpoch;
      await _histBox.put(id, _historyRecord(map));
    }
  });

  /// 已看集：键是剧集 id，值是 `{vid: 毫秒时间戳}`（时间戳让「回看」也能
  /// 保留记录，并可用于按时间清理）。官方把观看记录放在 SP
  /// `video_progress` 一族（`com/dragon/read/video/d.java:18-20`），
  /// 语义一致：**按 id 存、与进度分开**。
  @override
  Future<Set<String>> watchedEpisodeIds(String id) async {
    if (id.isEmpty) return <String>{};
    final raw = _watchedBox.get(id);
    if (raw is Map) return raw.keys.map((key) => key.toString()).toSet();
    // 旧数据兼容：早期若写成 List<String> 也认。
    if (raw is List) {
      return raw.map((value) => value.toString()).toSet();
    }
    return <String>{};
  }

  @override
  Future<void> markEpisodeWatched(String id, Iterable<String> episodeIds) {
    if (id.isEmpty) return Future<void>.value();
    final ids = episodeIds.where((value) => value.isNotEmpty).toSet();
    if (ids.isEmpty) return Future<void>.value();
    return _serialize(() async {
      final current = Map<String, dynamic>.from(
        _watchedBox.get(id) is Map
            ? _watchedBox.get(id) as Map
            : const <String, dynamic>{},
      );
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final episodeId in ids) {
        current.putIfAbsent(episodeId, () => now);
      }
      await _watchedBox.put(id, current);
    });
  }

  @override
  Future<void> forgetWatchedEpisodes(String id) {
    if (id.isEmpty) return Future<void>.value();
    return _serialize(() => _watchedBox.delete(id));
  }

  /// 删除单条观看记录（最近页的编辑/删除，官方 `w0.I0()` 调删除接口后
  /// 本地也要去掉）。返回是否真的删掉了一条。
  ///
  /// 只按 **contentId/kind** 精确匹配，不碰其它记录——工单要求「保护未选中
  /// 的历史记录」。
  Future<bool> removeHistoryEntry(String contentId, String kind) async {
    if (contentId.isEmpty) return false;
    return _serializeResult(() async {
      final keys = <dynamic>[];
      for (final key in _histBox.keys) {
        final record = _historyRecord(_histBox.get(key), id: key.toString());
        if (record == null) continue;
        if (_historyIdentity(record) == (kind, contentId)) keys.add(key);
      }
      if (keys.isEmpty) return false;
      await _histBox.deleteAll(keys);
      return true;
    });
  }

  /// 批量删除（编辑模式的「删除」）。返回删除条数。
  Future<int> removeHistoryEntries(
    Iterable<({String contentId, String kind})> targets,
  ) async {
    final wanted = targets
        .where((target) => target.contentId.isNotEmpty)
        .map((target) => (target.kind, target.contentId))
        .toSet();
    if (wanted.isEmpty) return 0;
    return _serializeResult(() async {
      final keys = <dynamic>[];
      for (final key in _histBox.keys) {
        final record = _historyRecord(_histBox.get(key), id: key.toString());
        if (record == null) continue;
        if (wanted.contains(_historyIdentity(record))) keys.add(key);
      }
      if (keys.isEmpty) return 0;
      await _histBox.deleteAll(keys);
      return keys.length;
    });
  }

  Future<void> clearHistory() {
    // Invalidate delayed wrapper saves synchronously, before they can enqueue.
    ReadingDataWriteGuard._forStore(this).history++;
    return _serialize(() async {
      final preferences = await SharedPreferences.getInstance();
      await _removeLegacySource(preferences, 'hist');
      await _histBox.clear();
      // 已看集也来自观看历史：清历史必须一并清掉，「删除历史」不能在
      // 选集面板里留下已看标记。
      await _watchedBox.clear();
    });
  }

  /// Removes saved history together with the per-day reading/playback time
  /// shown on the statistics page.
  Future<void> clearReadingData() {
    final generation = ReadingDataWriteGuard._forStore(this);
    generation.history++;
    generation.readTime++;
    // One queue keeps newer statistics behind the clear as well as history.
    // Legacy preservation can touch both boxes, so separate queues can cycle.
    return _serialize(() async {
      final preferences = await SharedPreferences.getInstance();
      await _removeLegacySource(preferences, 'hist');
      await _removeLegacySource(preferences, 'read_time_map');
      await _histBox.clear();
      await _readTimeBox.clear();
      await _watchedBox.clear();
    });
  }

  // Note: Clear retained migration sources before Hive so a restart cannot
  // resurrect deleted data; see
  // .agents/notes/implemented/bug-fix/2026-09-17-persistent-data-and-web-cancellation.md.
  Future<void> _removeLegacySource(
    SharedPreferences preferences,
    String key,
  ) async {
    // remove() updates the preferences cache even if its platform write fails.
    // Always retry the disk deletion; containsKey() is not proof it succeeded.
    if (!await preferences.remove(key)) {
      throw StateError('无法清除旧阅读数据，请重试');
    }
  }

  Map<String, Map<String, double>> readTimeSnapshot() {
    final out = <String, Map<String, double>>{};
    for (final key in _readTimeBox.keys) {
      final days = _readTimeRecord(_readTimeBox.get(key));
      if (days.isNotEmpty) out[key.toString()] = days;
    }

    // A saved baseline assigns old seconds to their media without deleting
    // the original data. Future novel seconds at the original ID remain its
    // own time, and retrying migration never adds the baseline twice.
    for (final key in _readTimeBox.keys) {
      final allocation = _legacyTimeAllocation(_readTimeBox.get(key));
      if (allocation == null) continue;
      _addDays(out, key.toString(), _visibleLegacyDays(_readTimeBox.get(key)));
    }
    for (final entry in _allocationBaselines().entries) {
      final sourceId = entry.key;
      // The source may have been evicted and then recreated for a novel. Only
      // its old component can belong to an allocation; fresh seconds survive.
      final oldDays = _readTimeRecord(_readTimeBox.get(sourceId));
      _subtractDays(oldDays, _newReadTime(_readTimeBox.get(sourceId)));
      final deductible = <String, double>{
        for (final day in entry.value.entries)
          if ((oldDays[day.key] ?? 0) > 0)
            day.key: day.value.clamp(0, oldDays[day.key]!).toDouble(),
      };
      _subtractDays(out[sourceId], deductible);
      if (out[sourceId]?.isEmpty ?? false) out.remove(sourceId);
    }

    // Records written by an older version can exist before init's migration
    // or before their first save. Normalize their statistics immediately.
    for (final key in _histBox.keys) {
      final record = _historyRecord(_histBox.get(key), id: key.toString());
      if (record == null) continue;
      final target = _legacyMediaKey(record);
      if (target == null) continue;
      final id = record['id'] as String;
      final remaining = out[id];
      if (remaining == null) continue;
      final days = Map<String, double>.from(remaining);
      _subtractDays(days, _newReadTime(_readTimeBox.get(id)));
      _addDays(out, target, days);
      _subtractDays(remaining, days);
      if (remaining.isEmpty) out.remove(id);
    }
    // A migrated identity can merge an allocation with its own days; cap the
    // user-visible window so every identity reports at most the retention.
    return {
      for (final entry in out.entries) entry.key: _keepNewestDays(entry.value),
    };
  }

  Map<String, double> _keepNewestDays(Map<String, double> days) {
    if (days.length <= readTimeRetentionDays) return days;
    final dated = <String, DateTime>{};
    final undated = <String>[];
    for (final key in days.keys) {
      final date = _parseDayKey(key);
      if (date == null) {
        undated.add(key);
      } else {
        dated[key] = date;
      }
    }
    if (dated.length <= readTimeRetentionDays) return days;
    final keys = dated.keys.toList()
      ..sort((a, b) => dated[a]!.compareTo(dated[b]!));
    final kept = keys.sublist(keys.length - readTimeRetentionDays);
    return {
      for (final key in kept) key: days[key]!,
      for (final key in undated) key: days[key]!,
    };
  }

  Future<Map<String, Map<String, double>>> readTimeMap() async =>
      readTimeSnapshot();

  /// The media kind recorded with each read-time identity, when known. Used by
  /// statistics to open read-time-only rows with the right content type.
  Map<String, String> readTimeKindSnapshot() {
    final out = <String, String>{};
    for (final key in _readTimeBox.keys) {
      final raw = _readTimeBox.get(key);
      final kind = raw is Map ? raw[_kindKey] : null;
      if (kind is String && kind.trim().isNotEmpty) {
        out[key.toString()] = kind.trim();
      }
    }
    return out;
  }

  @override
  Future<void> accumulateReadTime(
    String bookId,
    String kind,
    double seconds, {
    DateTime? at,
  }) {
    if (!seconds.isFinite || seconds <= 0 || bookId.isEmpty) {
      return Future<void>.value();
    }
    final day = _dayKey(at ?? DateTime.now());
    return _serialize(() async {
      final history = _historyRecord(_histBox.get(bookId), id: bookId);
      final legacy = history != null && _legacyMediaKey(history) != null;
      final newTime = !legacy || history['kind'] != kind;
      if (legacy && newTime) {
        // This callback already owns the queue. Preserve directly so a failed
        // history insert cannot make new novel seconds part of the old media.
        await _preserveLegacyMediaInWrite(history);
      }
      final raw = _readTimeBox.get(bookId);
      final perBook = _readTimeStorage(raw);
      final days = _readTimeRecord(raw);
      perBook[day] = (days[day] ?? 0) + seconds;
      final kindLabel = kind.trim();
      if (kindLabel.isNotEmpty) perBook[_kindKey] = kindLabel;
      if (newTime) {
        final newDays = _newReadTime(raw);
        newDays[day] = (newDays[day] ?? 0) + seconds;
        // Persist the counter and its classification atomically.
        perBook[_newTimeKey] = newDays;
      }
      perBook[_touchedKey] = (at ?? DateTime.now()).millisecondsSinceEpoch;
      _pruneRecordDays(perBook);
      await _readTimeBox.put(bookId, perBook);
      await _trimReadTimeIdentities();
    });
  }

  static (String, String) _historyIdentity(Map<String, dynamic> record) => (
    record['kind']?.toString() ?? 'book',
    (record['contentId'] ?? record['id']).toString(),
  );

  static String? _legacyMediaKey(Map<String, dynamic> record) {
    final kind = record['kind'];
    if (record['contentId'] != null || (kind != 'audio' && kind != 'manga')) {
      return null;
    }
    return '$kind:${record['id']}';
  }

  Future<void> _preserveLegacyMedia(Map<String, dynamic> record) {
    if (_legacyMediaKey(record) == null) return Future<void>.value();
    return _serialize(() => _preserveLegacyMediaInWrite(record));
  }

  Future<void> _preserveLegacyMediaInWrite(Map<String, dynamic> record) async {
    final target = _legacyMediaKey(record);
    if (target == null) return;
    final id = record['id'] as String;
    if (!_histBox.containsKey(target)) {
      await _histBox.put(target, {...record, 'id': target, 'contentId': id});
    }
    final current = _readTimeBox.get(target);
    final previous = _legacyTimeAllocation(current);
    final source = _readTimeBox.get(id);
    final days = _readTimeRecord(source);
    _subtractDays(days, _newReadTime(source));
    // A retry can find both an existing allocation and newly migrated days.
    // Add only old seconds that have not already been assigned to any media.
    final live = _liveAllocationBaselines()[id] ?? <String, double>{};
    final assigned = Map<String, double>.from(live);
    _mergeMaxDays(assigned, _allocatedReadTime(source));
    _subtractDays(days, assigned);
    final allocated = previous?.$1 == id ? previous!.$2 : <String, double>{};
    final discarded = previous?.$1 == id && current is Map
        ? _discardedLegacyDays(current)
        : <String, double>{};
    if (days.isNotEmpty) {
      // A retired allocation can be followed by an SP migration backfill.
      // Carry its high-water mark into the new allocation, without displaying
      // the retired seconds again. The target write alone is retry-safe.
      final carry = _allocatedReadTime(source);
      _subtractDays(carry, live);
      for (final day in carry.entries) {
        allocated[day.key] = (allocated[day.key] ?? 0) + day.value;
        discarded[day.key] = (discarded[day.key] ?? 0) + day.value;
      }
    }
    for (final day in days.entries) {
      allocated[day.key] = (allocated[day.key] ?? 0) + day.value;
    }
    final nextRecord = <String, dynamic>{
      ..._readTimeStorage(current),
      _legacyTimeKey: {
        'sourceId': id,
        'days': allocated,
        if (discarded.isNotEmpty) 'discardedDays': discarded,
      },
      _touchedKey: DateTime.now().millisecondsSinceEpoch,
    };
    _pruneRecordDays(nextRecord);
    if (_hasReadTimeData(nextRecord)) {
      await _readTimeBox.put(target, nextRecord);
    } else if (_readTimeBox.containsKey(target)) {
      // Never keep an empty preservation artifact: it would count against the
      // identity cap and could evict a record that holds real seconds.
      await _readTimeBox.delete(target);
    }
    if (source is Map) {
      // The source keeps its own copy of the days; prune it too so the
      // allocation above does not re-credit an over-window bucket.
      final sourceRecord = _readTimeStorage(source);
      _pruneRecordDays(sourceRecord);
      final touched = _finiteNumber(source[_touchedKey]);
      if (touched != null) sourceRecord[_touchedKey] = touched;
      if (_hasReadTimeData(sourceRecord)) {
        await _readTimeBox.put(id, sourceRecord);
      } else if (_readTimeBox.containsKey(id)) {
        await _readTimeBox.delete(id);
      }
    }
    await _trimReadTimeIdentities();
  }

  static (String, Map<String, double>)? _legacyTimeAllocation(dynamic raw) {
    if (raw is! Map) return null;
    final value = raw[_legacyTimeKey];
    if (value is! Map ||
        value['sourceId'] is! String ||
        value['days'] is! Map) {
      return null;
    }
    final id = value['sourceId'] as String;
    return id.isEmpty ? null : (id, _readTimeRecord(value['days']));
  }

  static Map<String, double> _discardedLegacyDays(dynamic raw) {
    final legacy = raw is Map ? raw[_legacyTimeKey] : null;
    return legacy is Map ? _readTimeRecord(legacy['discardedDays']) : {};
  }

  static Map<String, double> _visibleLegacyDays(dynamic raw) {
    final days = _legacyTimeAllocation(raw)?.$2 ?? <String, double>{};
    _subtractDays(days, _discardedLegacyDays(raw));
    return days;
  }

  static Map<String, double> _allocatedReadTime(dynamic raw) =>
      raw is Map ? _readTimeRecord(raw[_allocatedTimeKey]) : {};

  Map<String, Map<String, double>> _liveAllocationBaselines() {
    final baselines = <String, Map<String, double>>{};
    for (final raw in _readTimeBox.values) {
      final allocation = _legacyTimeAllocation(raw);
      if (allocation != null) _addDays(baselines, allocation.$1, allocation.$2);
    }
    return baselines;
  }

  Map<String, Map<String, double>> _allocationBaselines() {
    final baselines = _liveAllocationBaselines();
    for (final key in _readTimeBox.keys) {
      final assigned = _allocatedReadTime(_readTimeBox.get(key));
      if (assigned.isEmpty) continue;
      _mergeMaxDays(baselines.putIfAbsent(key.toString(), () => {}), assigned);
    }
    return baselines;
  }

  static void _mergeMaxDays(
    Map<String, double> target,
    Map<String, double> days,
  ) {
    for (final day in days.entries) {
      if (day.value > (target[day.key] ?? 0)) target[day.key] = day.value;
    }
  }

  static Map<String, dynamic> _readTimeStorage(dynamic raw) {
    final out = <String, dynamic>{..._readTimeRecord(raw)};
    if (raw is Map) {
      final legacy = raw[_legacyTimeKey];
      if (legacy is Map) {
        out[_legacyTimeKey] = {
          ...legacy,
          'days': _readTimeRecord(legacy['days']),
          if (legacy['discardedDays'] is Map)
            'discardedDays': _readTimeRecord(legacy['discardedDays']),
        };
      }
      if (raw[_newTimeKey] is Map) out[_newTimeKey] = _newReadTime(raw);
      if (raw[_allocatedTimeKey] is Map) {
        out[_allocatedTimeKey] = _allocatedReadTime(raw);
      }
      if (raw[_kindKey] is String) out[_kindKey] = raw[_kindKey];
      final touched = _finiteNumber(raw[_touchedKey]);
      if (touched != null) out[_touchedKey] = touched;
    }
    return out;
  }

  /// Keeps only the most recent [readTimeRetentionDays] day buckets, including
  /// the nested legacy/new-media day maps, so every record stays bounded.
  void _pruneRecordDays(Map<String, dynamic> record) {
    _pruneDayMap(record);
    final newDays = record[_newTimeKey];
    if (newDays is Map) _pruneDayMap(newDays);
    final allocated = record[_allocatedTimeKey];
    if (allocated is Map) _pruneDayMap(allocated);
    final legacy = record[_legacyTimeKey];
    if (legacy is Map && legacy['days'] is Map) {
      // Each stored map is bounded independently. The merged window is capped
      // in readTimeSnapshot(), which avoids dropping overlapping seconds.
      _pruneDayMap(legacy['days'] as Map);
      final discarded = legacy['discardedDays'];
      if (discarded is Map) {
        // Discarded seconds are part of the same allocation, not another
        // independent window that may outlive its high-water day buckets.
        final days = legacy['days'] as Map;
        discarded.removeWhere((key, _) => !days.containsKey(key));
      }
    }
  }

  void _pruneDayMap(Map<dynamic, dynamic> days) {
    final keep = readTimeRetentionDays;
    if (days.length <= keep) return;
    final dated = <dynamic, DateTime>{};
    for (final key in days.keys) {
      final date = key is String ? _parseDayKey(key) : null;
      if (date != null) dated[key] = date;
    }
    if (dated.length <= keep) return;
    final keys = dated.keys.toList()
      ..sort((a, b) => dated[a]!.compareTo(dated[b]!));
    for (final key in keys.take(keys.length - keep)) {
      days.remove(key);
    }
  }

  Future<void> _trimReadTimeIdentities() async {
    if (_readTimeBox.length <= maxReadTimeIdentities) return;
    final entries = <({dynamic key, num touched, bool hasData})>[];
    for (final key in _readTimeBox.keys) {
      final raw = _readTimeBox.get(key);
      entries.add((
        key: key,
        touched: raw is Map ? (_finiteNumber(raw[_touchedKey]) ?? 0) : 0,
        hasData: _hasReadTimeData(raw),
      ));
    }
    entries.sort((a, b) {
      if (a.hasData != b.hasData) return a.hasData ? 1 : -1;
      return a.touched.compareTo(b.touched);
    });
    final removeCount = entries.length - maxReadTimeIdentities;
    if (removeCount <= 0) return;
    final doomed = entries.take(removeCount).map((entry) => entry.key).toSet();
    // Note: Allocation/source records can be evicted independently. See
    // .agents/notes/implemented/bug-fix/2026-09-17-reviewed-runtime-boundaries.md.
    // Keep the assigned baseline on surviving sources before removing a
    // target. A failed delete leaves both copies, combined by max, not sum.
    final baselines = _allocationBaselines();
    final sources = <dynamic, dynamic>{};
    for (final key in doomed) {
      final allocation = _legacyTimeAllocation(_readTimeBox.get(key));
      if (allocation == null || doomed.contains(allocation.$1)) continue;
      final sourceId = allocation.$1;
      final source = _readTimeBox.get(sourceId);
      if (source is! Map) continue;
      final record = _readTimeStorage(source);
      record[_allocatedTimeKey] = baselines[sourceId]!;
      _pruneRecordDays(record);
      sources[sourceId] = record;
    }
    if (sources.isNotEmpty) await _readTimeBox.putAll(sources);
    await _readTimeBox.deleteAll(doomed);
  }

  static DateTime? _parseDayKey(String key) {
    final parts = key.split('-');
    if (parts.length != 3) return null;
    final year = int.tryParse(parts[0]);
    final month = int.tryParse(parts[1]);
    final day = int.tryParse(parts[2]);
    if (year == null || month == null || day == null) return null;
    if (year < 1 || year > 9999) return null;
    if (month < 1 || month > 12 || day < 1 || day > 31) return null;
    return DateTime(year, month, day);
  }

  static Map<String, double> _newReadTime(dynamic raw) =>
      raw is Map ? _readTimeRecord(raw[_newTimeKey]) : {};

  static void _addDays(
    Map<String, Map<String, double>> totals,
    String id,
    Map<String, double> days,
  ) {
    if (days.isEmpty) return;
    final target = totals.putIfAbsent(id, () => <String, double>{});
    for (final day in days.entries) {
      target[day.key] = (target[day.key] ?? 0) + day.value;
    }
  }

  static void _subtractDays(
    Map<String, double>? target,
    Map<String, double> days,
  ) {
    if (target == null) return;
    for (final day in days.entries) {
      final remaining = (target[day.key] ?? 0) - day.value;
      if (remaining > 0) {
        target[day.key] = remaining;
      } else {
        target.remove(day.key);
      }
    }
  }

  static String _dayKey(DateTime d) => '${d.year}-${d.month}-${d.day}';

  static num? _finiteNumber(dynamic value) {
    final number = value is num
        ? value
        : value is String
        ? num.tryParse(value)
        : null;
    return number != null && number.isFinite ? number : null;
  }

  static Map<String, dynamic>? _historyRecord(dynamic raw, {String? id}) {
    if (raw is! Map) return null;
    final record = <String, dynamic>{
      for (final entry in raw.entries)
        if (entry.key is String) entry.key as String: entry.value,
    };
    final recordId = id ?? record['id']?.toString();
    if (recordId == null || recordId.isEmpty) return null;
    record['id'] = recordId;
    for (final key in [
      'time',
      'episode',
      'position',
      'maxScroll',
      'progress',
    ]) {
      final number = _finiteNumber(record[key]);
      if (number == null || number < 0) {
        record.remove(key);
      } else if (key == 'time') {
        // DateTime cannot represent timestamps beyond this range.
        record[key] = number <= 8640000000000000 ? number.toInt() : 0;
      } else if (key == 'episode') {
        record[key] = number.toInt();
      } else {
        record[key] = key == 'progress'
            ? number.clamp(0, 1).toDouble()
            : number.toDouble();
      }
    }
    return record;
  }

  static Map<String, double> _readTimeRecord(dynamic raw) {
    if (raw is! Map) return {};
    return {
      for (final entry in raw.entries)
        // The stored media-kind is metadata, not a day counter; a numeric
        // String kind must never be parsed into a fake reading day.
        if (entry.key != _kindKey && entry.key != _touchedKey)
          if (_finiteNumber(entry.value) case final seconds?)
            if (seconds >= 0) entry.key.toString(): seconds.toDouble(),
    };
  }
}
