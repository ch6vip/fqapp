part of 'library_page.dart';

/// 书架 / 浏览历史 / 收藏行共用的展示模型与历史字段读取。原来写在
/// `library_page.dart` 里；属于页面的数据整理职责，拆出来给状态类与各
/// 版式共用。
class _ShelfEntry {
  final MediaItem item;

  /// Stable identity of the row: `kind:contentId`, i.e. the same key the shelf
  /// box and the history dedupe use.
  final String selectionKey;

  /// 历史 / 删除 API 用的内容标识（`kind:contentId` 的 contentId 部分）：
  /// 历史条目取存储记录的 `contentId ?? id`（与 LibraryStore 的
  /// _historyIdentity 一致），书架条目取 `seriesId ?? id`。
  final String contentId;

  /// Last read time in milliseconds; null when the work has no history yet.
  final int? readTime;

  /// 加入书架时间，仅书架条目有值。
  final int addedAt;
  final double? progress;
  final int? episode;

  /// 目录总章数。旧历史没有这个字段（null），书架回退到百分比显示。
  final int? chapterCount;
  final int? latestChapterCount;
  final bool importedResume;

  const _ShelfEntry({
    required this.item,
    required this.selectionKey,
    required this.contentId,
    required this.addedAt,
    this.readTime,
    this.progress,
    this.episode,
    this.chapterCount,
    this.latestChapterCount,
    this.importedResume = false,
  });

  factory _ShelfEntry.fromRecord(
    ShelfRecord record,
    Map<String, dynamic>? history, {
    int? latestChapterCount,
  }) => _ShelfEntry(
    item: record.item,
    selectionKey:
        '${record.item.kind}:${record.item.seriesId ?? record.item.id}',
    contentId: record.item.seriesId ?? record.item.id,
    addedAt: record.addedAt.millisecondsSinceEpoch,
    readTime: _timeOf(history),
    progress: _progressOf(history),
    episode: _episodeOf(history),
    chapterCount: _chapterCountOf(history),
    latestChapterCount: latestChapterCount,
    importedResume:
        record.item.kind == 'book' &&
        history?['fanqieImported'] == true &&
        history?['chapterId'] != null,
  );

  factory _ShelfEntry.fromHistory(Map<String, dynamic> history) {
    final item = MediaItem(
      id: historyContentId(history),
      title: history['title']?.toString() ?? '未知作品',
      cover: history['cover']?.toString() ?? '',
      author: history['author']?.toString() ?? '',
      badge: '',
      ep: history['ep']?.toString() ?? '',
      kind: history['kind']?.toString() ?? 'book',
      seriesId: history['seriesId']?.toString(),
      episodeId: history['episodeId']?.toString(),
    );
    final contentId = historyContentId(history);
    return _ShelfEntry(
      item: item,
      selectionKey: '${item.kind}:$contentId',
      contentId: contentId,
      addedAt: 0,
      readTime: _timeOf(history),
      progress: _progressOf(history),
      episode: _episodeOf(history),
      chapterCount: _chapterCountOf(history),
      importedResume:
          item.kind == 'book' &&
          history['fanqieImported'] == true &&
          history['chapterId'] != null,
    );
  }

  /// 是否读到最后一章（含章内进度）。
  ///
  /// 官方用「共 N 章·已读完」（strings `bm6`）表达这个状态，而不是把百分比
  /// 四舍五入成 100%——总章数多、剩余章数少时 100% 无法区分「差一点」和
  /// 「读完了」（issue #110 第 3 条）。
  bool get _finished {
    final total = _totalChapterCount;
    final chapter = episode;
    if (total == null || chapter == null) return false;
    if (chapter < total - 1) return false;
    final value = progress;
    return value == null || value >= 1;
  }

  /// 新增章节优先显示「更新」，其余情况显示真实进度。
  ///
  /// 读完时不再显示 100%，让「已读完」只由 [readingText] 表达一次。
  String? get badgeText {
    if (_hasUpdate) return '更新';
    if (_finished) return null;
    final total = _totalChapterCount;
    final chapter = episode;
    // 有总章数时用章序号，读者能看出「还剩多少章」。
    if (total != null && chapter != null && chapter >= 0) {
      return '${chapter + 1}/$total';
    }
    final value = progress;
    if (value == null || value <= 0) return null;
    return '${(value * 100).round()}%';
  }

  /// 宫格副信息 / 列表进度行。
  ///
  /// 有总章数时对齐官方：“第12章 · 共84章”，读完则是“共84章·已读完”
  /// （strings `bm6`）。旧历史没有总章数，回退到原来的百分比。
  String? get readingText {
    final total = _totalChapterCount;
    final chapter = episode;
    if (total != null && chapter != null && chapter >= 0) {
      if (_finished) return '共$total章·已读完';
      return '${_hasUpdate ? '更新 · ' : ''}第${chapter + 1}章 · 共$total章';
    }
    final parts = <String>[];
    if (chapter != null && chapter >= 0) parts.add('第${chapter + 1}章');
    final value = progress;
    if (value != null && value > 0) {
      parts.add('${(value * 100).round()}%');
    }
    return parts.isEmpty ? null : parts.join(' · ');
  }

  bool get _hasUpdate =>
      chapterCount != null &&
      latestChapterCount != null &&
      latestChapterCount! > chapterCount!;

  int? get _totalChapterCount =>
      chapterCount != null &&
      (latestChapterCount == null || latestChapterCount! < chapterCount!)
      ? chapterCount
      : latestChapterCount;

  String? get metaText {
    if (item.author.trim().isNotEmpty) return item.author.trim();
    final relative = _relativeTime(readTime);
    if (relative != null) return relative;
    return bookshelfKindLabel(item.kind);
  }

  String? get infoText =>
      readingText ?? _relativeTime(readTime) ?? bookshelfKindLabel(item.kind);

  String? get subtitleText => item.author.trim().isEmpty
      ? bookshelfKindLabel(item.kind)
      : item.author.trim();
}

double? _progressOf(Map<String, dynamic>? history) {
  final value = history?['progress'];
  if (value is! num || value <= 0) return null;
  return value.toDouble().clamp(0, 1);
}

int? _episodeOf(Map<String, dynamic>? history) {
  final value = history?['episode'];
  return value is num && value >= 0 ? value.toInt() : null;
}

/// 目录总章数，用于区分「读到末尾」与「全书读完」（issue #110）。
int? _chapterCountOf(Map<String, dynamic>? history) {
  final value = history?['chapterCount'];
  return value is num && value > 0 ? value.toInt() : null;
}

int? _timeOf(Map<String, dynamic>? history) {
  final value = history?['time'];
  return value is num && value > 0 ? value.toInt() : null;
}

String? _relativeTime(int? time) {
  if (time == null) return null;
  final date = DateTime.fromMillisecondsSinceEpoch(time);
  final difference = DateTime.now().difference(date);
  if (difference.isNegative || difference.inMinutes < 1) return '刚刚';
  if (difference.inHours < 1) return '${difference.inMinutes}分钟前';
  if (difference.inDays < 1) return '${difference.inHours}小时前';
  if (difference.inDays < 7) return '${difference.inDays}天前';
  return '${date.month}月${date.day}日';
}
