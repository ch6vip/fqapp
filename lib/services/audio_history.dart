import '../models/media_item.dart';
import 'library_store.dart';
import 'media_history_store.dart';

/// Shares pending writes across listening pages and the detail resume action.
class AudioHistory {
  static final _writes = Expando<Future<void>>('audio history writes');
  final ReaderStore store;

  AudioHistory(ReaderStore store) : store = scopedHistoryStore(store, 'audio');

  Future<Map<String, dynamic>?> load(String bookId) async {
    await _writes[store];
    final entry = await store.historyEntry(bookId);
    // Novel scroll offsets and audio seconds can use the same upstream ID.
    // An untyped older entry is not enough evidence to resume listening.
    return entry?['kind'] == 'audio' ? entry : null;
  }

  Future<void> save(Map<String, dynamic> entry, {double listenedSeconds = 0}) {
    final snapshot = {...entry, 'kind': 'audio'};
    final previous = _writes[store] ?? Future<void>.value();
    final write = previous.then((_) async {
      if (listenedSeconds.isFinite && listenedSeconds > 0) {
        try {
          await store.accumulateReadTime(
            snapshot['id'] as String,
            'audio',
            listenedSeconds,
          );
        } catch (_) {
          // Statistics must not prevent saving the listening position.
        }
      }
      try {
        await store.addHistory(snapshot);
      } catch (_) {
        // Keep playback and later writes usable after a storage failure.
      }
    });
    _writes[store] = write;
    return write.whenComplete(() {
      if (identical(_writes[store], write)) _writes[store] = null;
    });
  }
}

/// Stable chapter identity wins over a directory index that may have changed.
int? resumeAudioChapterIndex(
  Map<String, dynamic>? saved,
  List<Chapter> chapters,
) {
  if (saved?['kind'] != 'audio') return null;
  final id = saved?['chapterId'] ?? saved?['episodeId'];
  if (id is String && id.isNotEmpty) {
    final index = chapters.indexWhere((chapter) => chapter.itemId == id);
    return index < 0 ? null : index;
  }
  final index = saved?['episode'];
  if (index is! num ||
      !index.isFinite ||
      index != index.truncateToDouble() ||
      index < 0 ||
      index >= chapters.length) {
    return null;
  }
  return index.toInt();
}
