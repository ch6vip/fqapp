import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../../services/ai_reading/ai_controller.dart';
import '../../../services/ai_reading/ai_models.dart';
import '../../../services/chapter_cache_store.dart';
import '../../../services/library_store.dart';
import '../../../widgets/home/home_design.dart';
import '../../../widgets/home/home_feed_states.dart';
import '../../../widgets/settings/settings_widgets.dart';
import 'ai_settings_widgets.dart';

/// Manage formal AI corrections without clearing every book at once.
///
/// Level one groups cached results by book. Opening a book shows the chapter
/// status index, where individual chapters (and chapters sharing the same
/// canonical hash) can be cleared as a batch.
class AiCacheManagePage extends StatefulWidget {
  const AiCacheManagePage({super.key});

  @override
  State<AiCacheManagePage> createState() => _AiCacheManagePageState();
}

class _AiCacheBook {
  const _AiCacheBook({
    required this.bookId,
    required this.title,
    required this.entryCount,
    required this.chapterCount,
    required this.updatedAt,
  });

  final String bookId;
  final String title;
  final int entryCount;
  final int chapterCount;
  final DateTime updatedAt;
}

class _AiCacheManagePageState extends State<AiCacheManagePage> {
  final _controller = AiReadingController.instance;
  List<_AiCacheBook> _books = const [];
  bool _loading = true;
  bool _busy = false;
  bool _selecting = false;
  String? _error;
  final _selected = <String>{};

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  bool get _allSelected =>
      _books.isNotEmpty && _selected.length == _books.length;

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await _controller.init();
      if (!_controller.store.isAvailable) {
        throw StateError(_controller.store.status ?? 'AI 数据暂不可用');
      }
      final formal = await _controller.store.allFormal();
      final grouped = <String, List<AiFormalCacheEntry>>{};
      for (final entry in formal) {
        grouped.putIfAbsent(entry.bookId, () => []).add(entry);
      }
      final books = <_AiCacheBook>[];
      for (final item in grouped.entries) {
        final hashes = {for (final entry in item.value) entry.canonicalHash};
        final statuses = await _controller.chapterStatuses(item.key);
        final chapters = statuses
            .where(
              (status) =>
                  status.canonicalHash != null &&
                  hashes.contains(status.canonicalHash) &&
                  status.state != AiChapterCheckState.unchecked &&
                  status.state != AiChapterCheckState.running,
            )
            .length;
        final updatedAt = item.value
            .map((entry) => entry.updatedAt)
            .reduce((a, b) => a.isAfter(b) ? a : b);
        books.add(
          _AiCacheBook(
            bookId: item.key,
            title: await _resolveBookTitle(item.key),
            entryCount: item.value.length,
            chapterCount: chapters,
            updatedAt: updatedAt,
          ),
        );
      }
      books.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      if (!mounted) return;
      setState(() {
        _books = books;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '读取 AI 缓存失败：$error';
      });
    }
  }

  Future<String> _resolveBookTitle(String bookId) async {
    try {
      final cached =
          await ChapterCacheStore.instance.savedCatalogue(bookId) ??
          await ChapterCacheStore.instance.cachedBook(bookId);
      if (cached != null && cached.title.trim().isNotEmpty) {
        return cached.title.trim();
      }
    } catch (_) {
      // A missing catalogue only affects the label, never the cache itself.
    }
    try {
      final history = await LibraryStore.instance.historyEntry(bookId);
      final title = history?['title'];
      if (title is String && title.trim().isNotEmpty) return title.trim();
    } catch (_) {
      // Same as above: fall back to a stable short id.
    }
    return '书籍 ${bookId.length > 10 ? bookId.substring(0, 10) : bookId}';
  }

  void _toggleSelection(String bookId) {
    setState(() {
      if (!_selected.add(bookId)) _selected.remove(bookId);
    });
  }

  void _toggleSelectAll() {
    setState(() {
      if (_allSelected) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll(_books.map((book) => book.bookId));
      }
    });
  }

  Future<void> _openBook(_AiCacheBook book) async {
    if (_selecting) {
      _toggleSelection(book.bookId);
      return;
    }
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) =>
            AiCacheBookPage(bookId: book.bookId, bookTitle: book.title),
      ),
    );
    if (changed == true && mounted) unawaited(_load());
  }

  Future<void> _clearSelected() async {
    if (_busy || _selected.isEmpty) return;
    final confirmed = await showSettingsConfirmDialog(
      context: context,
      title: '清理 ${_selected.length} 本书的校对缓存？',
      message: '只删除正式校对结果和章节状态；反馈、保护、提示词和用量账本不受影响。',
      confirmLabel: '清理',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    setState(() => _busy = true);
    try {
      await _controller.clearFormalCacheForBooks({..._selected});
      if (!mounted) return;
      setState(() {
        _selected.clear();
        _selecting = false;
      });
      await _load();
      if (mounted) aiShowSnack(context, '已清理选中书籍的校对缓存');
    } catch (error) {
      if (mounted) aiShowSnack(context, '清理失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clearAll() async {
    if (_busy) return;
    final confirmed = await showSettingsConfirmDialog(
      context: context,
      title: '清空全部 AI 缓存？',
      message: '只删除已保存的正式校对结果，反馈、保护、提示词和用量账本不受影响。',
      confirmLabel: '清空',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    setState(() => _busy = true);
    try {
      await _controller.clearFormalCache();
      await _load();
      if (mounted) aiShowSnack(context, 'AI 缓存已清空');
    } catch (error) {
      if (mounted) aiShowSnack(context, '清空失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final canSelect = !_loading && _books.isNotEmpty;
    return SettingsScaffold(
      title: _selecting ? '已选 ${_selected.length} 本' : 'AI 校对缓存',
      actions: [
        if (canSelect)
          TextButton(
            onPressed: _busy
                ? null
                : () => setState(() {
                    _selecting = !_selecting;
                    if (!_selecting) _selected.clear();
                  }),
            child: Text(_selecting ? '取消' : '批量'),
          ),
        if (canSelect && !_selecting)
          PopupMenuButton<String>(
            tooltip: '更多',
            icon: Icon(LucideIcons.ellipsis_vertical, color: palette.ink),
            onSelected: (_) => unawaited(_clearAll()),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'all', child: Text('清空全部 AI 缓存')),
            ],
          ),
      ],
      bottom: _selecting
          ? PreferredSize(
              preferredSize: const Size.fromHeight(58),
              child: BottomAppBar(
                height: 58,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: [
                    TextButton(
                      onPressed: _busy ? null : _toggleSelectAll,
                      child: Text(_allSelected ? '取消全选' : '全选'),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: _selected.isEmpty || _busy
                          ? null
                          : _clearSelected,
                      child: const Text('清理选中'),
                    ),
                  ],
                ),
              ),
            )
          : null,
      body: _body(),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error case final error?) {
      return HomeStateView(
        icon: LucideIcons.triangle_alert,
        title: '读取失败',
        message: error,
        actionLabel: '重试',
        onAction: () => unawaited(_load()),
      );
    }
    if (_books.isEmpty) {
      return const HomeStateView(
        icon: LucideIcons.inbox,
        title: '暂无校对缓存',
        message: '校对过的章节会显示在这里，可以按书或按章清理。',
      );
    }
    final entries = _books.fold(0, (sum, book) => sum + book.entryCount);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        SettingsGroupCard(
          children: [
            SettingsRow(
              icon: LucideIcons.inbox,
              iconTile: true,
              title: '已缓存 ${_books.length} 本书',
              subtitle: '共 $entries 条校对结果 · 点击进入可按章清理',
            ),
          ],
        ),
        const SizedBox(height: 12),
        for (final book in _books) ...[
          SettingsGroupCard(
            showDividers: false,
            children: [
              SettingsRow(
                icon: LucideIcons.book_open,
                iconTile: true,
                title: book.title,
                subtitle: '${book.chapterCount} 章有缓存 · ${book.entryCount} 条结果',
                onTap: () => unawaited(_openBook(book)),
                trailing: _selecting
                    ? Checkbox(
                        value: _selected.contains(book.bookId),
                        onChanged: (_) => _toggleSelection(book.bookId),
                      )
                    : null,
              ),
            ],
          ),
          if (book != _books.last) const SizedBox(height: 8),
        ],
      ],
    );
  }
}

class _AiCacheChapter {
  const _AiCacheChapter({
    required this.status,
    required this.title,
    required this.order,
    required this.edits,
    required this.sharedChapters,
  });

  final AiChapterCheckStatus status;
  final String title;
  final int? order;
  final int edits;
  final int sharedChapters;

  String get hash => status.canonicalHash!;
}

class AiCacheBookPage extends StatefulWidget {
  const AiCacheBookPage({
    super.key,
    required this.bookId,
    required this.bookTitle,
  });

  final String bookId;
  final String bookTitle;

  @override
  State<AiCacheBookPage> createState() => _AiCacheBookPageState();
}

class _AiCacheBookPageState extends State<AiCacheBookPage> {
  final _controller = AiReadingController.instance;
  List<_AiCacheChapter> _chapters = const [];
  int _unlinked = 0;
  bool _loading = true;
  bool _busy = false;
  bool _selecting = false;
  String? _error;
  final _selected = <String>{};

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  bool get _allSelected =>
      _chapters.isNotEmpty && _selected.length == _chapters.length;

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await _controller.init();
      if (!_controller.store.isAvailable) {
        throw StateError(_controller.store.status ?? 'AI 数据暂不可用');
      }
      final formal = await _controller.store.allFormal();
      final entries = {
        for (final entry in formal)
          if (entry.bookId == widget.bookId) entry.canonicalHash: entry,
      };
      final statuses = await _controller.chapterStatuses(widget.bookId);
      final cached = statuses
          .where(
            (status) =>
                status.canonicalHash != null &&
                entries.containsKey(status.canonicalHash) &&
                status.state != AiChapterCheckState.unchecked &&
                status.state != AiChapterCheckState.running,
          )
          .toList(growable: false);
      final shared = <String, int>{};
      for (final status in cached) {
        shared.update(
          status.canonicalHash!,
          (value) => value + 1,
          ifAbsent: () => 1,
        );
      }
      final titles = <String, String>{};
      final order = <String, int>{};
      try {
        final book =
            await ChapterCacheStore.instance.savedCatalogue(widget.bookId) ??
            await ChapterCacheStore.instance.cachedBook(widget.bookId);
        if (book != null) {
          for (var i = 0; i < book.chapters.length; i++) {
            final chapter = book.chapters[i];
            order[chapter.itemId] = i;
            titles[chapter.itemId] = chapter.title.trim();
          }
        }
      } catch (_) {
        // Titles are cosmetic; ids remain usable without a cached catalogue.
      }
      final chapters = <_AiCacheChapter>[
        for (final status in cached)
          _AiCacheChapter(
            status: status,
            title: _chapterLabel(status, titles, order),
            order: order[status.chapterId],
            edits: entries[status.canonicalHash]!.edits.length,
            sharedChapters: shared[status.canonicalHash] ?? 1,
          ),
      ];
      chapters.sort((a, b) {
        final ao = a.order;
        final bo = b.order;
        if (ao != null && bo != null) return ao.compareTo(bo);
        if (ao != null) return -1;
        if (bo != null) return 1;
        return a.status.chapterId.compareTo(b.status.chapterId);
      });
      final knownHashes = {for (final chapter in chapters) chapter.hash};
      if (!mounted) return;
      setState(() {
        _chapters = chapters;
        _unlinked = entries.length - knownHashes.length;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '读取 AI 缓存失败：$error';
      });
    }
  }

  String _chapterLabel(
    AiChapterCheckStatus status,
    Map<String, String> titles,
    Map<String, int> order,
  ) {
    final title = titles[status.chapterId];
    if (title != null && title.isNotEmpty) return title;
    final index = order[status.chapterId];
    if (index != null) return '第${index + 1}章';
    final id = status.chapterId;
    return '章节 ${id.length > 12 ? id.substring(0, 12) : id}';
  }

  void _toggleSelection(String chapterId) {
    setState(() {
      if (!_selected.add(chapterId)) _selected.remove(chapterId);
    });
  }

  void _startSelection(String chapterId) {
    setState(() {
      _selecting = true;
      _selected.add(chapterId);
    });
  }

  void _toggleSelectAll() {
    setState(() {
      if (_allSelected) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll(_chapters.map((chapter) => chapter.status.chapterId));
      }
    });
  }

  Future<void> _clearSelected() async {
    if (_busy || _selected.isEmpty) return;
    final selected = _chapters
        .where((chapter) => _selected.contains(chapter.status.chapterId))
        .toList(growable: false);
    final hashes = {for (final chapter in selected) chapter.hash};
    final shared = _chapters
        .where((chapter) => hashes.contains(chapter.hash))
        .length;
    final confirmed = await showSettingsConfirmDialog(
      context: context,
      title: '清理 ${selected.length} 章的校对缓存？',
      message: shared > selected.length
          ? '同正文哈希的章节共享一条缓存，本次会一起失效（共 $shared 章）。反馈、保护、提示词和用量账本不受影响。'
          : '只删除正式校对结果和章节状态；反馈、保护、提示词和用量账本不受影响。',
      confirmLabel: '清理',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    setState(() => _busy = true);
    try {
      await _controller.clearFormalCacheForHashes(widget.bookId, hashes);
      if (!mounted) return;
      setState(() {
        _selected.clear();
        _selecting = false;
      });
      await _load();
      if (mounted) aiShowSnack(context, '已清理选中章节的校对缓存');
    } catch (error) {
      if (mounted) aiShowSnack(context, '清理失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clearBook() async {
    if (_busy) return;
    final confirmed = await showSettingsConfirmDialog(
      context: context,
      title: '清理《${widget.bookTitle}》的全部校对缓存？',
      message: '只删除正式校对结果和章节状态；反馈、保护、提示词和用量账本不受影响。',
      confirmLabel: '清理',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    setState(() => _busy = true);
    try {
      await _controller.clearFormalCacheForBooks({widget.bookId});
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted) aiShowSnack(context, '清理失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final canSelect = !_loading && _chapters.isNotEmpty;
    return SettingsScaffold(
      title: _selecting ? '已选 ${_selected.length} 章' : '本书校对缓存',
      actions: [
        if (canSelect)
          TextButton(
            onPressed: _busy
                ? null
                : () => setState(() {
                    _selecting = !_selecting;
                    if (!_selecting) _selected.clear();
                  }),
            child: Text(_selecting ? '取消' : '批量'),
          ),
        if (!_selecting && !_loading)
          PopupMenuButton<String>(
            tooltip: '更多',
            icon: Icon(LucideIcons.ellipsis_vertical, color: palette.ink),
            enabled: !_busy,
            onSelected: (_) => unawaited(_clearBook()),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'book', child: Text('清空本书缓存')),
            ],
          ),
      ],
      bottom: _selecting
          ? PreferredSize(
              preferredSize: const Size.fromHeight(58),
              child: BottomAppBar(
                height: 58,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: [
                    TextButton(
                      onPressed: _busy ? null : _toggleSelectAll,
                      child: Text(_allSelected ? '取消全选' : '全选'),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: _selected.isEmpty || _busy
                          ? null
                          : _clearSelected,
                      child: const Text('清理选中'),
                    ),
                  ],
                ),
              ),
            )
          : null,
      body: _body(),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error case final error?) {
      return HomeStateView(
        icon: LucideIcons.triangle_alert,
        title: '读取失败',
        message: error,
        actionLabel: '重试',
        onAction: () => unawaited(_load()),
      );
    }
    if (_chapters.isEmpty) {
      return HomeStateView(
        icon: LucideIcons.inbox,
        title: '本书暂无校对缓存',
        message: _unlinked > 0
            ? '有 $_unlinked 条缓存无法关联到章节，可用右上角清空本书缓存。'
            : '校对完成的章节会显示在这里。',
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        SettingsGroupCard(
          children: [
            SettingsRow(
              icon: LucideIcons.book_open,
              iconTile: true,
              title: widget.bookTitle,
              subtitle:
                  '${_chapters.length} 章有缓存'
                  '${_unlinked > 0 ? ' · 另有 $_unlinked 条未关联章节' : ''}',
            ),
          ],
        ),
        const SizedBox(height: 12),
        for (final chapter in _chapters) ...[
          SettingsGroupCard(
            showDividers: false,
            children: [
              SettingsRow(
                icon: LucideIcons.file_text,
                iconTile: true,
                title: chapter.title,
                subtitle: _chapterSubtitle(chapter),
                onTap: _selecting
                    ? () => _toggleSelection(chapter.status.chapterId)
                    : () => _startSelection(chapter.status.chapterId),
                trailing: _selecting
                    ? Checkbox(
                        value: _selected.contains(chapter.status.chapterId),
                        onChanged: (_) =>
                            _toggleSelection(chapter.status.chapterId),
                      )
                    : null,
              ),
            ],
          ),
          if (chapter != _chapters.last) const SizedBox(height: 8),
        ],
      ],
    );
  }

  String _chapterSubtitle(_AiCacheChapter chapter) {
    final state = chapter.status.state == AiChapterCheckState.failed
        ? '上次校对失败，缓存仍在'
        : '已校验';
    final edits = '${chapter.edits} 处修改';
    final shared = chapter.sharedChapters > 1
        ? ' · 同正文 ${chapter.sharedChapters} 章共享'
        : '';
    return '$state · $edits$shared';
  }
}
