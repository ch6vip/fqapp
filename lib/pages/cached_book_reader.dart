import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../services/chapter_cache_store.dart';
import '../services/connectivity_status.dart';
import '../services/library_store.dart';
import '../services/reader_history.dart';
import 'reader_page.dart';

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
