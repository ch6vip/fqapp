import 'library_store.dart';

final _scopedStores = Expando<Map<String, ReaderStore>>('media history stores');

/// Keeps progress units and reading time separate for media sharing a book ID.
/// Reusing the wrapper also lets ReaderHistory serialize writes across routes.
ReaderStore scopedHistoryStore(ReaderStore store, String kind) {
  if (store is _MediaHistoryStore) {
    if (store.kind == kind) return store;
    store = store.delegate;
  }
  final scopes = _scopedStores[store] ??= <String, ReaderStore>{};
  return scopes.putIfAbsent(kind, () => _MediaHistoryStore(store, kind));
}

/// The upstream ID remains distinct from the key used in local history.
String historyContentId(Map<String, dynamic> entry) =>
    (entry['contentId'] ?? entry['id'])?.toString() ?? '';

String historyStatisticsId(Map<String, dynamic> entry) {
  final kind = entry['kind'];
  if (kind == 'audio' || kind == 'manga') {
    return '$kind:${historyContentId(entry)}';
  }
  return (entry['contentId'] != null
              ? entry['id']
              : entry['bookId'] ?? entry['id'])
          ?.toString() ??
      '';
}

class _MediaHistoryStore implements ReaderStore {
  final ReaderStore delegate;
  final String kind;

  _MediaHistoryStore(this.delegate, this.kind) {
    ReadingDataWriteGuard.shareScope(this, delegate);
  }

  String _key(String id) => '$kind:$id';

  @override
  Future<Map<String, dynamic>?> historyEntry(String id) async {
    final saved =
        await delegate.historyEntry(_key(id)) ??
        await delegate.historyEntry(id);
    if (saved == null || saved['kind'] != kind) return null;
    return {...saved, 'id': id, 'contentId': id};
  }

  @override
  Future<void> addHistory(Map<String, dynamic> entry) async {
    final id = entry['id']?.toString() ?? '';
    if (id.isEmpty) return;
    await delegate.addHistory({
      ...entry,
      'id': _key(id),
      'contentId': id,
      'kind': kind,
    });
  }

  @override
  Future<void> updateProgress(
    String id,
    int episode,
    double progress, {
    String? chapterId,
    double? position,
    double? maxScroll,
  }) async {
    final guard = ReadingDataWriteGuard(this);
    // A legacy record is copied into the new scope on its first update.
    if (await delegate.historyEntry(_key(id)) == null) {
      final saved = await historyEntry(id);
      if (saved == null || !guard.canWriteHistory) return;
      await addHistory(saved);
    }
    if (!guard.canWriteHistory) return;
    await delegate.updateProgress(
      _key(id),
      episode,
      progress,
      chapterId: chapterId,
      position: position,
      maxScroll: maxScroll,
    );
  }

  @override
  Future<void> accumulateReadTime(
    String bookId,
    String kind,
    double seconds, {
    DateTime? at,
  }) => delegate.accumulateReadTime(_key(bookId), this.kind, seconds, at: at);
}
