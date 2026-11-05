import 'package:flutter/foundation.dart';

import '../../../models/media_item.dart';
import '../../../models/shelf_identity.dart';

/// The immutable row model the archive carousel renders.
///
/// Upstream `ArchiveFileCarousel` reads `Novel` plus `LibraryState`
/// (`W/lib/archive_wave.dart:467-633`). fqapp keeps the same visual grammar
/// but flattens all reading state into this one value so the carousel has no
/// service dependency.
@immutable
class ArchiveShelfEntry {
  const ArchiveShelfEntry({
    required this.item,
    this.read = false,
    this.finished = false,
    this.fraction,
    this.chapterLabel,
    this.totalChapters,
    this.sourceLabel,
    this.local = false,
    this.cached = false,
    this.updated = false,
  });

  final MediaItem item;
  final bool read;
  final bool finished;

  /// Whole-book progress 0..1, taken directly from `_ShelfEntry.progress`.
  /// This is *not* an in-chapter fraction: fqapp already folds the chapter
  /// position into it (`F/lib/pages/reader/reader_page_progress.dart`).
  final double? fraction;

  /// `_ShelfEntry.readingText`, e.g. `第12章 · 共84章`.
  final String? chapterLabel;

  final int? totalChapters;

  /// 番茄 / 书旗 / 本地 / 短剧 / 漫剧 / …
  final String? sourceLabel;
  final bool local;
  final bool cached;
  final bool updated;

  String get contentKey => shelfContentKeyOf(item);

  /// Compatibility alias; equal to [contentKey].
  String get identity => contentKey;

  bool get isVideo => item.kind == 'video' || item.kind == 'manju';

  /// 已完结 / 连载中 / null. Video entries expose their episode label instead.
  String? get statusLabel {
    if (isVideo) {
      final ep = item.ep.trim();
      return ep.isEmpty ? null : ep;
    }
    return switch (item.creationStatus) {
      0 => '已完结',
      1 => '连载中',
      _ => null,
    };
  }

  /// `作者 · 状态`, or `作者 · 全 N 集` for video entries.
  ///
  /// fqapp video/manga records do not always store a bare episode count:
  /// `series_detail_page` writes `episodeLabel` (`全66集`) and `drama_page`
  /// writes `共 N 集`. Only a pure number gets the `全 N 集` wrapper; any other
  /// label is shown verbatim so it never becomes `全全12集集`.
  String get subtitleLine {
    final author = item.author.trim();
    final String? status;
    if (isVideo) {
      final ep = item.ep.trim();
      status = ep.isEmpty
          ? null
          : _episodeCountPattern.hasMatch(ep)
          ? '全$ep集'
          : ep;
    } else {
      status = statusLabel;
    }
    if (author.isEmpty) return status ?? '';
    return status == null ? author : '$author · $status';
  }

  /// The narrow caption's second line. Always carries reading progress.
  String get detailLine => chapterLabel ?? subtitleLine;

  /// Badges for the cover face: update/cache state, then the source label.
  List<String> get coverBadges => [
    if (updated) '更新' else if (cached) '缓存',
    if (sourceLabel case final label? when label.isNotEmpty) label,
  ];

  /// FQ-/SQ- file code, matching the search result tiles' convention.
  String get fileCode {
    final prefix = item.source == 'shuqi' ? 'SQ' : 'FQ';
    final id = item.id.trim();
    final numeric = int.tryParse(id);
    if (numeric != null) {
      return '$prefix-${numeric.toString().padLeft(5, '0')}';
    }
    return id.isEmpty ? '$prefix-UNFILED' : '$prefix-$id';
  }

  /// 尚未开始阅读 / 已读完 / chapterLabel / 共 N 章.
  ///
  /// A read entry with neither a chapter label nor a chapter total has no
  /// progress to report; it returns '' rather than inventing a fifth state.
  String get progressText {
    if (!read) return '尚未开始阅读';
    if (finished) return '已读完';
    final label = chapterLabel;
    if (label != null && label.isNotEmpty) return label;
    final total = totalChapters;
    if (total != null && total > 0) return '共$total章';
    return '';
  }
}

final RegExp _episodeCountPattern = RegExp(r'^[0-9]+$');

/// The source/kinds label shown on the cover and in the wide information pane.
String? archiveSourceLabel(MediaItem item, {required bool local}) {
  if (local) return '本地';
  if (item.source == 'shuqi') return '书旗';
  return switch (item.kind) {
    'video' => '短剧',
    'manju' => '漫剧',
    'manga' => '漫画',
    'audio' => '听书',
    _ => '番茄',
  };
}
