import 'library_store.dart';

/// Keeps resume reads behind pending saves from earlier reader page instances.
class ReaderHistory {
  static final _writes = Expando<Future<void>>('reader history writes');
  final ReaderStore store;

  ReaderHistory(this.store);

  Future<Map<String, dynamic>?> load(String bookId) async {
    await _writes[store];
    return store.historyEntry(bookId);
  }

  Future<void> save(Map<String, dynamic> entry, {bool createHistory = false}) {
    final guard = ReadingDataWriteGuard(store);
    final snapshot = Map<String, dynamic>.from(entry);
    final previous = _writes[store] ?? Future<void>.value();
    final write = previous.then((_) async {
      if (!guard.canWriteHistory) return;
      try {
        // Every caller already supplies the full snapshot. Retrying it also
        // retries a failed first insert; a partial update could otherwise
        // overwrite a legacy record belonging to another media kind.
        await store.addHistory(snapshot);
      } catch (_) {
        // Storage errors must not interrupt reading or poison later saves.
      }
    });
    _writes[store] = write;
    return write.whenComplete(() {
      if (identical(_writes[store], write)) _writes[store] = null;
    });
  }
}
