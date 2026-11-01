part of 'library_store.dart';

/// 历史记录计数与裁剪：本地记录超过 100 条时裁到 50 条，导入记录另有上限。
///
/// 做成同库扩展（part 与主文件共享私有成员），行为与原实现一致，只是从
/// 1100+ 行的主文件里拆出来。计数缓存与 [LibraryStore._localHistoryCount]
/// 的失效规则保持不变。
extension _HistoryTrim on LibraryStore {
  /// Counts non-imported history records without copying or sorting them.
  int _localHistoryCountNow() {
    final cached = _localHistoryCount;
    if (cached != null) return cached;
    var count = 0;
    for (final key in _histBox.keys) {
      final raw = _histBox.get(key);
      if (raw is! Map || raw['fanqieImported'] != true) count++;
    }
    return _localHistoryCount = count;
  }

  /// Keeps the cached count in step with one in-place history write.
  void _noteHistoryWrite(Object? before, Map<String, dynamic> after) {
    final count = _localHistoryCount;
    if (count == null) return;
    final wasLocal =
        before != null && (before is! Map || before['fanqieImported'] != true);
    final isLocal = after['fanqieImported'] != true;
    final delta = (isLocal ? 1 : 0) - (wasLocal ? 1 : 0);
    if (delta != 0) _localHistoryCount = count + delta;
  }

  /// 本地历史超过 100 条时裁到 50 条，再给导入记录单独设上限。
  Future<void> _trimHistory(
    String insertedId,
    Map<String, dynamic> inserted,
  ) async {
    // Trim history to 50 entries once it grows past 100 (leaves headroom so
    // we don't prune on every single write). The gate counts non-imported
    // records: imported history is exempt from this trim, so a large import
    // can hold the box above 100 with nothing local to prune — rebuilding the
    // whole snapshot on every write would then be wasted work.
    if (_localHistoryCountNow() > 100) {
      // Legacy backups must not make fifty books look like a hundred books.
      final retained =
          historySnapshot().take(50).map(LibraryStore._historyIdentity).toSet()
            // Never trim the record this write just inserted, even without a time.
            ..add(LibraryStore._historyIdentity(inserted));
      final oldestKeys = <dynamic>[];
      for (final key in _histBox.keys) {
        final record = LibraryStore._historyRecord(
          _histBox.get(key),
          id: key.toString(),
        );
        if (record == null ||
            (record['fanqieImported'] != true &&
                !retained.contains(LibraryStore._historyIdentity(record)))) {
          oldestKeys.add(key);
        }
      }
      await _histBox.deleteAll(oldestKeys);
      _localHistoryCount = null;
    }
    // Imported records are exempt from the 50-entry trim above, so a bulk
    // import is not wiped by the next local write. They still get their own
    // bound: past the cap, drop the oldest imported records.
    if (_histBox.length > LibraryStore._importedHistoryCap) {
      final imported = <MapEntry<dynamic, Map<String, dynamic>>>[];
      for (final key in _histBox.keys) {
        final record = LibraryStore._historyRecord(
          _histBox.get(key),
          id: key.toString(),
        );
        if (record != null && record['fanqieImported'] == true) {
          imported.add(MapEntry(key, record));
        }
      }
      if (imported.length > LibraryStore._importedHistoryCap) {
        imported.sort(
          (a, b) => LibraryStore._historyTime(
            a.value,
          ).compareTo(LibraryStore._historyTime(b.value)),
        );
        final doomed = [
          for (final entry in imported.take(
            imported.length - LibraryStore._importedHistoryCap,
          ))
            // Never trim the record this write just inserted.
            if (entry.key != insertedId) entry.key,
        ];
        await _histBox.deleteAll(doomed);
      }
    }
  }
}
