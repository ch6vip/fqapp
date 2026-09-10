import '../models/media_item.dart';
import 'library_store.dart';

/// Shares pending playback writes across page instances and the detail page's
/// resume action. Captured progress must finish saving before it is read again.
class PlayerHistory {
  static final _writes = Expando<Future<void>>('playback history writes');
  final ReaderStore store;

  PlayerHistory(this.store);

  Future<Map<String, dynamic>?> load(String bookId) async {
    await _writes[store];
    return store.historyEntry(bookId);
  }

  Future<void> save(Map<String, dynamic> entry, {double watchedSeconds = 0}) {
    final snapshot = Map<String, dynamic>.from(entry);
    final previous = _writes[store] ?? Future<void>.value();
    final write = previous
        .then((_) async {
          if (watchedSeconds > 0) {
            try {
              await store.accumulateReadTime(
                snapshot['id'] as String,
                snapshot['kind'] == 'manju' ? 'manju' : 'video',
                watchedSeconds,
              );
            } catch (_) {
              // A statistics failure must not discard the resume position.
            }
          }
          await store.addHistory(snapshot);
        })
        .catchError((Object _) {});
    _writes[store] = write;
    return write;
  }
}

/// Prefer the stable episode identity; older entries only stored an index.
int? resumeEpisodeIndex(Map<String, dynamic>? saved, List<Chapter> episodes) {
  final id = saved?['episodeId'] ?? saved?['chapterId'];
  if (id is String && id.isNotEmpty) {
    final index = episodes.indexWhere((episode) => episode.itemId == id);
    return index < 0 ? null : index;
  }
  final index = saved?['episode'];
  if (index is! num ||
      !index.isFinite ||
      index != index.truncateToDouble() ||
      index < 0 ||
      index >= episodes.length) {
    return null;
  }
  return index.toInt();
}
