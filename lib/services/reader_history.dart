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
    final snapshot = Map<String, dynamic>.from(entry);
    final previous = _writes[store] ?? Future<void>.value();
    final write = previous.then((_) async {
      try {
        if (createHistory) {
          await store.addHistory(snapshot);
        } else {
          await store.updateProgress(
            snapshot['id'] as String,
            snapshot['episode'] as int,
            snapshot['progress'] as double,
            chapterId: snapshot['chapterId'] as String,
            position: snapshot['position'] as double,
            maxScroll: snapshot['maxScroll'] as double,
          );
        }
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
