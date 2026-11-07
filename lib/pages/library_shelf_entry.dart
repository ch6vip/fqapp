part of 'library_page.dart';

/// 书架 / 浏览历史 / 收藏行共用的展示模型与历史字段读取。
///
/// 实现 [ShelfProjectable]，排序 / 阅读状态 / 来源筛选由
/// [ShelfProjection] 统一完成；[contentKey] 与 `ShelfStore.keyOf`、
/// 分组 assignment、立体书架 identity 同源（design §1.3 #5）。
class _ShelfEntry implements ShelfProjectable {
  final MediaItem item;

  /// 历史 / 删除 API 用的内容标识（`kind:contentId` 的 contentId 部分）：
  /// 历史条目取存储记录的 `contentId ?? id`（与 LibraryStore 的
  /// _historyIdentity 一致），书架条目取 `seriesId ?? id`。
  @override
  final String contentId;

  /// Last read time in milliseconds; null when the work has no history yet.
  @override
  final int? readTime;

  /// 加入书架时间，仅书架条目有值。
  @override
  final int addedAt;
  final double? progress;
  final int? episode;

  /// 目录总章数。旧历史没有这个字段（null），书架回退到百分比显示。
  final int? chapterCount;
  final int? latestChapterCount;
  final bool importedResume;

  /// 番茄历史导入标记（fqapp 专有行为，tile meta 显示「番茄导入」）。
  final bool fanqieImported;

  /// 离线缓存扫描命中（仅番茄小说）。
  final bool cached;

  /// 历史条目的身份以 `LibraryStore._historyIdentity`（contentId ?? id）为准；
  /// 书架条目直接由 [MediaItem] 推导。两者在短剧 seriesId 与 contentId
  /// 不一致时可能不同，历史侧必须与历史索引保持同一把键。
  final String? contentKeyOverride;

  const _ShelfEntry({
    required this.item,
    required this.contentId,
    required this.addedAt,
    this.readTime,
    this.progress,
    this.episode,
    this.chapterCount,
    this.latestChapterCount,
    this.importedResume = false,
    this.fanqieImported = false,
    this.cached = false,
    this.contentKeyOverride,
  });

  factory _ShelfEntry.fromRecord(
    ShelfRecord record,
    Map<String, dynamic>? history, {
    int? latestChapterCount,
    bool cached = false,
  }) => _ShelfEntry(
    item: record.item,
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
    fanqieImported: history?['fanqieImported'] == true,
    cached: cached,
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
    return _ShelfEntry(
      item: item,
      contentId: historyContentId(history),
      addedAt: 0,
      readTime: _timeOf(history),
      progress: _progressOf(history),
      episode: _episodeOf(history),
      chapterCount: _chapterCountOf(history),
      importedResume:
          item.kind == 'book' &&
          history['fanqieImported'] == true &&
          history['chapterId'] != null,
      fanqieImported: history['fanqieImported'] == true,
      contentKeyOverride: ShelfIdentity.contentKeyFor(
        item.kind,
        historyContentId(history),
        source: item.source,
      ),
    );
  }

  /// 源限定身份键：番茄 `book:123`，书旗 `shuqi/book:123`。
  @override
  String get contentKey =>
      contentKeyOverride ?? ShelfIdentity.contentKeyOf(item);

  /// 行 / 选中 / 立体书架共用的稳定键。
  String get selectionKey => contentKey;

  @override
  String get kind => item.kind;

  @override
  String get source => item.source;

  @override
  String get title => item.title;

  @override
  String get author => item.author;

  bool get isLocal => ImportedBookStore.isLocalBookId(item.id);

  /// 是否读到最后一章（含章内进度）。
  ///
  /// 官方用「共 N 章·已读完」（strings `bm6`）表达这个状态，而不是把百分比
  /// 四舍五入成 100%——总章数多、剩余章数少时 100% 无法区分「差一点」和
  /// 「读完了」（issue #110 第 3 条）。
  @override
  bool get finished {
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
    if (finished) return null;
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
      if (finished) return '共$total章·已读完';
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

  /// 立体书架行模型：整书进度直接透传，不在这里重算。
  ArchiveShelfEntry toArchive() => ArchiveShelfEntry(
    item: item,
    read: readTime != null,
    finished: finished,
    fraction: progress,
    chapterLabel: readingText,
    totalChapters: _totalChapterCount,
    sourceLabel: archiveSourceLabel(item, local: isLocal),
    local: isLocal,
    cached: cached,
    updated: _hasUpdate,
  );
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
