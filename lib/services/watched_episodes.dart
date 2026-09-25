import '../models/media_item.dart';
import 'library_store.dart';

/// 已看集（F07）。
///
/// 官方规则：**按 vid 逐集记录**，不是「续播点之前的都算看过」——
/// 选集格子的判据是 `VideoGlobalManager.b(seriesId).c(vid)` 返回非空
/// （`hj3/r0.java:445` 的 `bf3.b.b.q(seriesId, vid, ctx)`），
/// 存储落在 `video_progress` 一族 SP 上（`com/dragon/read/video/d.java:18-20`）。
///
/// 本类的三条纪律：
/// 1. **以剧集/视频 id 为键**，列表重排不会串集；
/// 2. **与续播位置分开持久化**（续播仍在历史记录里）；
/// 3. **迁移不补造中间集**：旧数据只有「最后一个集下标」，只能把那一集
///    本身算已看，绝不把前面的集补进来。
class WatchedEpisodes {
  WatchedEpisodes(this.store);

  final ReaderStore store;

  /// 正在进行的读改写。同一剧的多次标记必须串行，否则后写的会覆盖先写的。
  static final _pending = Expando<Future<void>>('watched episode writes');

  Future<Set<String>> ids(String seriesId) async {
    await _pending[store];
    return store.watchedEpisodeIds(seriesId);
  }

  /// 标记若干集已看（按 id 并集）。
  Future<void> mark(String seriesId, Iterable<String> episodeIds) {
    final ids = episodeIds.where((value) => value.isNotEmpty).toSet();
    if (seriesId.isEmpty || ids.isEmpty) return Future<void>.value();
    final previous = _pending[store] ?? Future<void>.value();
    final write = previous
        .then((_) => store.markEpisodeWatched(seriesId, ids))
        .catchError((Object _) {});
    _pending[store] = write;
    return write;
  }

  /// 从旧历史记录迁移一次。
  ///
  /// 旧记录里只有 `episode`（最后观看的集下标）与 `episodeId`。
  /// 迁移**只把这一集**标记为已看，前面的集一律不算——工单明确禁止
  /// 「凭最后观看集数补造中间集的观看记录」。
  ///
  /// 返回本次实际迁移的 id（空集表示没有可迁移的）。
  Future<Set<String>> migrateFromHistory({
    required String seriesId,
    required Map<String, dynamic>? saved,
    required List<Chapter> episodes,
  }) async {
    if (seriesId.isEmpty || saved == null || episodes.isEmpty) {
      return <String>{};
    }
    if (saved['watchedMigrated'] == true) return <String>{};
    final index = resumeIndex(saved, episodes);
    if (index == null) return <String>{};
    final episodeId = episodes[index].itemId;
    if (episodeId.isEmpty) return <String>{};
    await mark(seriesId, [episodeId]);
    final marked = Map<String, dynamic>.from(saved);
    marked['watchedMigrated'] = true;
    return {episodeId};
  }

  /// 旧数据里定位「最后观看的集」：优先稳定 id，其次下标。
  static int? resumeIndex(Map<String, dynamic> saved, List<Chapter> episodes) {
    final id = saved['episodeId'] ?? saved['chapterId'];
    if (id is String && id.isNotEmpty) {
      final index = episodes.indexWhere((episode) => episode.itemId == id);
      if (index >= 0) return index;
    }
    final index = saved['episode'];
    if (index is! num ||
        !index.isFinite ||
        index != index.truncateToDouble() ||
        index < 0 ||
        index >= episodes.length) {
      return null;
    }
    return index.toInt();
  }
}

/// 把已看 id 集合映射回下标集合（选集面板仍然按下标渲染）。
Set<int> watchedIndexes(Set<String> ids, List<Chapter> episodes) {
  if (ids.isEmpty) return const <int>{};
  final out = <int>{};
  for (var i = 0; i < episodes.length; i++) {
    if (ids.contains(episodes[i].itemId)) out.add(i);
  }
  return out;
}
