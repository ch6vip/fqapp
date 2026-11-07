import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../services/reader_bookmark_store.dart';
import '../../services/reader_preferences.dart';
import '../wenku/src/app_text.dart';
import '../wenku/wenku_glass.dart';
import '../wenku/wenku_overlay.dart';
import 'reader_theme.dart';

/// Local-only port of Wenku8_Flutter ebcd7f1 reader_tools.dart::_bookmarks
/// (1603–1770), its tools header and reader_bookmark_excerpt.dart's compact
/// quote. No fabricated chapter fraction, annotation, category or account data.
class ReaderBookmarksPanel extends StatefulWidget {
  const ReaderBookmarksPanel({
    super.key,
    required this.bookId,
    required this.preset,
    required this.store,
    required this.onAdd,
  });

  final String bookId;
  final ReaderThemePreset preset;
  final ReaderBookmarkStore store;

  /// Parent captures a source anchor and persists it before returning. The
  /// panel never saves a second time or substitutes an underline for a bookmark.
  final Future<ReaderBookmark?> Function() onAdd;

  @override
  State<ReaderBookmarksPanel> createState() => _ReaderBookmarksPanelState();
}

class _ReaderBookmarksPanelState extends State<ReaderBookmarksPanel> {
  List<ReaderBookmark>? _records;
  bool _loading = true;
  bool _adding = false;
  String? _deleting;
  String? _readError;
  String? _actionError;
  ReaderBookmark? _retryDelete;
  int _generation = 0;
  int _epoch = 0;

  @override
  void initState() {
    super.initState();
    widget.store.changes.addListener(_changed);
    unawaited(_load());
  }

  @override
  void didUpdateWidget(ReaderBookmarksPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store != widget.store || oldWidget.bookId != widget.bookId) {
      oldWidget.store.changes.removeListener(_changed);
      widget.store.changes.addListener(_changed);
      _epoch++;
      _records = null;
      _adding = false;
      _deleting = null;
      _actionError = null;
      _retryDelete = null;
      unawaited(_load());
    }
  }

  void _changed() => unawaited(_load());

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _readError = null;
    });
    try {
      final records = await widget.store.loadBook(widget.bookId);
      if (!mounted || generation != _generation) return;
      setState(() {
        _records = records;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        // Keep the last successful list visible; absence of data is not empty.
        _readError = '书签读取失败，请重试';
        _loading = false;
      });
    }
  }

  Future<void> _add() async {
    if (_adding || _deleting != null) return;
    final epoch = _epoch;
    setState(() {
      _adding = true;
      _actionError = null;
      _retryDelete = null;
    });
    try {
      final record = await widget.onAdd();
      if (!mounted || epoch != _epoch) return;
      if (record == null || record.bookId != widget.bookId) {
        setState(() => _actionError = '当前位置暂不可用，请重试');
      } else {
        await _load();
      }
    } catch (_) {
      if (mounted && epoch == _epoch) {
        setState(() => _actionError = '书签保存失败，请重试');
      }
    } finally {
      if (mounted && epoch == _epoch) setState(() => _adding = false);
    }
  }

  Future<void> _delete(BuildContext context, ReaderBookmark record) async {
    if (_adding || _deleting != null) return;
    final epoch = _epoch;
    final store = widget.store;
    setState(() {
      _deleting = record.key;
      _actionError = null;
      _retryDelete = null;
    });
    try {
      final confirmed = await confirmArchiveAction(
        context,
        title: '删除书签？',
        message: '删除“${record.title}”的本地书签？此操作不可撤销。',
        confirmLabel: '删除书签',
        confirmKey: const ValueKey('reader-bookmark-confirm-delete'),
        cancelKey: const ValueKey('reader-bookmark-cancel-delete'),
        reduceMotion: widget.preset.isEink,
      );
      if (!mounted || epoch != _epoch || !confirmed) return;
      await store.remove(record.key);
      if (!mounted || epoch != _epoch) return;
      await _load();
    } catch (_) {
      if (mounted && epoch == _epoch) {
        setState(() {
          _actionError = '书签删除失败，请重试';
          _retryDelete = record;
        });
      }
    } finally {
      if (mounted && epoch == _epoch) setState(() => _deleting = null);
    }
  }

  @override
  void dispose() {
    _generation++;
    _epoch++;
    widget.store.changes.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Theme(
    data: widget.preset.theme(Theme.of(context)),
    child: Builder(builder: _buildPanel),
  );

  Widget _buildPanel(BuildContext context) {
    final records = _records;
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final previewHeight =
        36 +
        (records ?? const <ReaderBookmark>[])
            .take(4)
            .fold<double>(
              0,
              (height, record) =>
                  height + 66 + (record.text.isEmpty ? 0 : 62 * scale),
            );
    final hasError = _readError != null || _actionError != null;
    final bodyHeight = records == null || records.isEmpty
        ? (hasError ? 216.0 : 132.0)
        : math.min(
            math.min(480.0, MediaQuery.sizeOf(context).height * .56),
            previewHeight + (hasError ? 84 : 0),
          );
    final busy = _adding || _deleting != null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
          child: Row(
            children: [
              const SizedBox(width: 10),
              const Expanded(
                child: AppText(
                  '书签',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
              ),
              GlassIconButton(
                key: const ValueKey('reader-add-bookmark'),
                icon: CupertinoIcons.add,
                label: _adding ? '正在保存书签' : '添加当前位置书签',
                liveGlass: false,
                transparent: true,
                onPressed: busy ? null : _add,
              ),
              GlassIconButton(
                key: const ValueKey('reader-bookmarks-close'),
                icon: CupertinoIcons.xmark,
                label: '关闭书签',
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
        ),
        Flexible(
          child: SizedBox(
            height: bodyHeight,
            child: CustomScrollView(
              key: const ValueKey('reader-bookmarks-scroll'),
              primary: false,
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                  sliver: SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        AppText(
                          records == null ? '本地书签' : '本书 ${records.length} 条记录',
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                        if (_loading) ...[
                          const SizedBox(height: 8),
                          const LinearProgressIndicator(),
                        ],
                        if (_readError != null)
                          _errorRow(
                            context,
                            _readError!,
                            const ValueKey('reader-bookmarks-retry-read'),
                            _load,
                          ),
                        if (_actionError != null)
                          _errorRow(
                            context,
                            _actionError!,
                            const ValueKey('reader-bookmarks-retry-action'),
                            busy
                                ? null
                                : () {
                                    final record = _retryDelete;
                                    if (record == null) {
                                      unawaited(_add());
                                    } else {
                                      unawaited(_delete(context, record));
                                    }
                                  },
                          ),
                      ],
                    ),
                  ),
                ),
                if (records != null && records.isEmpty)
                  const SliverPadding(
                    padding: EdgeInsets.fromLTRB(24, 20, 24, 28),
                    sliver: SliverToBoxAdapter(
                      child: AppText('点右上角＋保存当前位置。书签仅保存在本机。'),
                    ),
                  )
                else if (records != null)
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                    sliver: SliverList.builder(
                      itemCount: records.length,
                      itemBuilder: (context, index) {
                        final record = records[index];
                        return JellyTapSurface(
                          key: ValueKey('reader-bookmark-${record.key}'),
                          onTap: busy
                              ? null
                              : () => Navigator.pop(context, record),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 8,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Row(
                                  key: ValueKey(
                                    'reader-bookmark-heading-${record.key}',
                                  ),
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          AppText(
                                            record.title,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                          const SizedBox(height: 2),
                                          AppText(
                                            '本地书签',
                                            style: TextStyle(
                                              fontSize: 11,
                                              color: Theme.of(
                                                context,
                                              ).colorScheme.onSurfaceVariant,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    GlassIconButton(
                                      key: ValueKey(
                                        'reader-bookmark-delete-${record.key}',
                                      ),
                                      icon: CupertinoIcons.trash,
                                      label: '删除书签 ${record.title}',
                                      liveGlass: false,
                                      transparent: true,
                                      onPressed: busy
                                          ? null
                                          : () => _delete(context, record),
                                    ),
                                  ],
                                ),
                                if (record.text.isNotEmpty)
                                  _excerpt(context, record),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _errorRow(
    BuildContext context,
    String message,
    Key key,
    VoidCallback? retry,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      AppText(
        message,
        style: TextStyle(color: Theme.of(context).colorScheme.error),
      ),
      GlassTextButton(key: key, onPressed: retry, child: const AppText('重试')),
    ],
  );

  Widget _excerpt(BuildContext context, ReaderBookmark record) => DecoratedBox(
    key: ValueKey('bookmark-quote-${record.key}'),
    decoration: BoxDecoration(
      border: Border(
        left: BorderSide(
          color: widget.preset.textColor.withValues(alpha: .64),
          width: 2,
        ),
      ),
    ),
    child: Padding(
      padding: const EdgeInsets.only(left: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppText(
            '摘录',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          AppText(
            record.text,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 15, height: 1.5),
          ),
        ],
      ),
    ),
  );
}
