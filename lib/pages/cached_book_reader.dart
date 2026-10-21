import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../services/chapter_cache_store.dart';
import '../services/connectivity_status.dart';
import '../services/library_store.dart';
import '../services/media_history_store.dart';
import '../services/player_history.dart';
import '../services/reader_history.dart';
import 'comic_reader_page.dart';
import 'reader_page.dart';

/// 最近读过且本地还留着目录时直接续读，不等待详情页或网络探测。
///
/// 小说额外要求「上次读到的章节正文仍在缓存」，否则会把用户送进一个读不出
/// 内容的阅读器；漫画没有正文缓存（图片始终联网取，且带 per-launch 能力值，
/// 不能落盘），只要求目录缓存存在。
Future<bool> openRecentBook(
  BuildContext context,
  MediaItem item, {
  ChapterCache? cache,
  ReaderStore? readerStore,
}) async {
  final kind = item.kind;
  if ((kind != 'book' && kind != 'manga') || item.id.isEmpty) return false;
  final isManga = kind == 'manga';
  final store = cache ?? ChapterCacheStore.instance;
  final baseStore = readerStore ?? LibraryStore.instance;
  // 漫画进度写在独立作用域里（见 ComicReaderPage 的 scopedHistoryStore），
  // 用未分作用域的 store 读不到，会误判成「没读过」。
  final historyStore = isManga
      ? scopedHistoryStore(baseStore, 'manga')
      : baseStore;
  CachedBook? book;
  int? index;
  try {
    final saved = await ReaderHistory(historyStore).load(item.id);
    if (saved == null || (saved['kind'] != null && saved['kind'] != kind)) {
      return false;
    }
    // 漫画没有正文缓存，只能看目录是否存过；小说要求正文还在（下面再判）。
    book = isManga
        ? await store.savedCatalogue(item.id)
        : await store.cachedBook(item.id);
    if (book == null) return false;
    index = resumeEpisodeIndex({
      ...saved,
      if (saved['chapterId'] != null)
        'chapterId': saved['chapterId'].toString(),
    }, book.chapters);
    if (index == null) return false;
    if (!isManga &&
        !(await store.cachedChapterIds(
          item.id,
        )).contains(book.chapters[index].itemId)) {
      return false;
    }
  } catch (_) {
    // 缓存或历史不可用时，交给原有加载和重试入口。
    return false;
  }
  if (!context.mounted) return false;
  final cachedBook = book;
  final startIndex = index;
  final title = item.title.isNotEmpty ? item.title : cachedBook.title;
  final cover = item.cover.isNotEmpty ? item.cover : cachedBook.cover;
  await Navigator.push<void>(
    context,
    MaterialPageRoute(
      builder: (_) => isManga
          ? ComicReaderPage(
              bookId: item.id,
              title: title,
              cover: cover,
              chapters: cachedBook.chapters,
              startIndex: startIndex,
              // 阅读器自己会写默认缓存，注入的缓存供测试与调用方覆盖。
              readerStore: baseStore,
              cache: cache,
              shelfItem: item,
            )
          : ReaderPage(
              bookId: item.id,
              title: title,
              cover: cover,
              chapters: cachedBook.chapters,
              startIndex: startIndex,
              // 默认缓存由阅读器自行读取，保留在线段评、预取和正文刷新。
              chapterCache: cache,
              readerStore: baseStore,
              shelfItem: item,
            ),
    ),
  );
  return true;
}

/// 用本地缓存直接起阅读器，全程不碰网络。
///
/// 官方客户端从书架、下载列表点书就是直接进阅读器（`ReaderBundleBuilder`），
/// 中间没有那个要联网取目录的页面——离线时「下载了却读不了」正是那个中间页
/// 造成的。这里把同一套逻辑收在一处，离线缓存页、书架、详情页兜底共用，
/// 免得三处各写一遍再各自走样。
///
/// 返回 false 表示这本书没有可读的缓存章节（或缓存章节都不在目录里），
/// 调用方应回退到联网路径。
///
/// Note: 离线续读入口的取舍、以及为何联网时不抢在详情页前面 — 见
/// .agents/notes/implemented/feature/2026-10-10-offline-resume-entry.md
Future<bool> openCachedBook(
  BuildContext context, {
  required CachedBook book,
  ChapterCache? cache,
  ReaderStore? readerStore,
}) async {
  final store = cache ?? ChapterCacheStore.instance;
  final historyStore = readerStore ?? LibraryStore.instance;
  final cached = await store.cachedChapterIds(book.id);
  if (cached.isEmpty || !context.mounted) return false;
  Map<String, dynamic>? saved;
  try {
    saved = await ReaderHistory(historyStore).load(book.id);
  } catch (_) {
    // An unavailable history store must not block cached chapters.
  }
  if (!context.mounted) return false;
  final index = cachedStartIndex(book, cached, saved);
  if (index < 0) return false;
  await Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) => ReaderPage(
        bookId: book.id,
        title: book.title,
        cover: book.cover,
        chapters: book.chapters,
        startIndex: index,
        // 注入缓存即声明「调用方自带数据」：阅读页据此不再为段评/目录去联网
        // （见 ReaderPage._loadIdeas），这正是离线可读的前提。
        chapterCache: store,
        readerStore: historyStore,
      ),
    ),
  );
  return true;
}

/// 书架点书的离线取舍：只有小说、无网、且本地确实有缓存章节时，才返回可以直读
/// 的那本书；返回 null 表示调用方应照旧走详情页（联网路径）。
///
/// 联网时不抢在详情页前面，是为了不把段评、章节目录预览这些联网能力悄悄降级。
Future<CachedBook?> cachedBookForOfflineOpen(
  MediaItem item, {
  required ChapterCache cache,
  required ConnectivityView connectivity,
}) async {
  if (item.kind != 'book' || item.id.isEmpty || connectivity.online) {
    return null;
  }
  CachedBook? catalogue;
  try {
    catalogue = await cache.cachedBook(item.id);
  } catch (_) {
    // 缓存读不出来就照旧走详情页，别把用户卡在书架上。
    return null;
  }
  if (catalogue == null) return null;
  // 目录被清掉时 store 只能用 bookId 兜底标题，书架上现成的书名/封面更准。
  return CachedBook(
    id: catalogue.id,
    title: item.title.isNotEmpty ? item.title : catalogue.title,
    cover: item.cover.isNotEmpty ? item.cover : catalogue.cover,
    chapters: catalogue.chapters,
  );
}

/// 离线续读的起读下标：先认上次读到的那一章，再退到阅读进度，最后退到目录里
/// 第一个有缓存的章节。返回 -1 表示缓存章节一个都不在目录里。
@visibleForTesting
int cachedStartIndex(
  CachedBook book,
  Set<String> cached,
  Map<String, dynamic>? saved,
) {
  if (book.chapters.isEmpty) return -1;
  var index = book.chapters.indexWhere(
    (chapter) => chapter.itemId == saved?['chapterId']?.toString(),
  );
  if (saved?['fanqieImported'] == true &&
      saved?['chapterId'] != null &&
      (index < 0 || !cached.contains(book.chapters[index].itemId))) {
    // A different cached chapter must not silently replace an imported anchor.
    return -1;
  }
  if (index < 0) {
    final episode = num.tryParse(saved?['episode']?.toString() ?? '');
    index = (episode != null && episode.isFinite ? episode.toInt() : 0).clamp(
      0,
      book.chapters.length - 1,
    );
  }
  if (!cached.contains(book.chapters[index].itemId)) {
    index = book.chapters.indexWhere(
      (chapter) => cached.contains(chapter.itemId),
    );
  }
  return index;
}
