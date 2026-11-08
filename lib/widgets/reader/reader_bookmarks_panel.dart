import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../services/reader_bookmark_store.dart';
import '../../services/reader_preferences.dart';
import '../app_ui/app_ui_scope.dart';
import '../wenku/src/app_text.dart';
import '../wenku/wenku_glass.dart';
import '../wenku/wenku_overlay.dart';
import 'reader_panel_scroll_anchor.dart';
import 'reader_theme.dart';
import 'settings/reader_settings_widgets.dart';

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
  final _scroll = ScrollController();
  late final _anchor = ReaderPanelScrollAnchor(_scroll);
  bool? _wasClassic;
  bool _captureScheduled = false;

  @override
  void initState() {
    super.initState();
    widget.store.changes.addListener(_changed);
    _scroll.addListener(_scheduleAnchorCapture);
    unawaited(_load());
  }

  void _scheduleAnchorCapture() {
    if (_captureScheduled) return;
    _captureScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _captureScheduled = false;
      if (mounted) _anchor.capture();
    });
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
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Classic and archive mount different scrollables, and bookmark excerpts
    // make rows variable height. Keep the top visible record (id + in-row
    // offset) rather than a pixel offset; records, errors and in-flight
    // operations stay in this State either way.
    final classic = AppUiScope.isClassic(context);
    if (_wasClassic != null && _wasClassic != classic) {
      _anchor.restore(
        fallbackOffset: _scroll.hasClients ? _scroll.offset : null,
      );
    }
    _wasClassic = classic;
  }

  @override
  void dispose() {
    _generation++;
    _epoch++;
    _anchor.cancel();
    _scroll.removeListener(_scheduleAnchorCapture);
    _scroll.dispose();
    widget.store.changes.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _scheduleAnchorCapture();
    return Theme(
      data: widget.preset.theme(Theme.of(context)),
      child: Builder(
        builder: (context) => AppUiScope.isClassic(context)
            ? _buildClassic(context)
            : _buildArchive(context),
      ),
    );
  }

  /// Classic: the pre-#291 Material bookmark list — shared frame, add action
  /// in the header, excerpt rows and a plain delete icon. Store, concurrency
  /// generation, source anchor and the confirm route stay unchanged.
  Widget _buildClassic(BuildContext context) {
    final preset = widget.preset;
    final records = _records;
    final busy = _adding || _deleting != null;
    return ReaderSettingsSheetFrame(
      preset: preset,
      title: '书签',
      closeTooltip: '关闭书签',
      scrollKey: const ValueKey('reader-bookmarks-scroll'),
      maxHeightFactor: MediaQuery.viewInsetsOf(context).bottom > 0 ? 1 : .72,
      actions: [
        IconButton(
          key: const ValueKey('reader-add-bookmark'),
          tooltip: _adding ? '正在保存书签' : '添加当前位置书签',
          onPressed: busy ? null : _add,
          icon: Icon(
            LucideIcons.bookmark_plus,
            size: 20,
            color: preset.textColor,
          ),
        ),
      ],
      body: KeyedSubtree(
        // Stable owner for the panel body: the harness closes the panel
        // through this key and it exists for the empty/loading states too.
        key: const ValueKey('reader-bookmarks-scroll'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 16, 6),
              child: Text(
                records == null ? '本地书签' : '本书 ${records.length} 条记录',
                key: const ValueKey('reader-bookmarks-status'),
                style: TextStyle(fontSize: 12, color: preset.mutedTextColor),
              ),
            ),
            if (_loading)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: LinearProgressIndicator(
                  minHeight: 2,
                  color: preset.accentColor,
                  backgroundColor: preset.fieldColor,
                ),
              ),
            if (_readError != null)
              _classicErrorRow(
                preset,
                _readError!,
                const ValueKey('reader-bookmarks-retry-read'),
                () => unawaited(_load()),
              ),
            if (_actionError != null)
              _classicErrorRow(
                preset,
                _actionError!,
                const ValueKey('reader-bookmarks-retry-action'),
                busy ? null : _retryAction,
              ),
            Divider(height: 1, color: preset.borderColor),
            Expanded(
              child: records == null
                  ? const SizedBox.shrink()
                  : records.isEmpty
                  ? Center(
                      child: Text(
                        '还没有书签，点右上角保存当前位置',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: preset.mutedTextColor),
                      ),
                    )
                  : ListView.builder(
                      key: const ValueKey('reader-bookmarks-list'),
                      controller: _scroll,
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      itemCount: records.length,
                      itemBuilder: (context, index) {
                        final record = records[index];
                        return KeyedSubtree(
                          key: _anchor.keyFor(record.key, index: index),
                          child: _classicRow(preset, record, index, busy),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  void _retryAction() {
    final record = _retryDelete;
    if (record == null) {
      unawaited(_add());
    } else {
      unawaited(_delete(context, record));
    }
  }

  Widget _classicErrorRow(
    ReaderThemePreset preset,
    String message,
    Key key,
    VoidCallback? onRetry,
  ) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 2, 12, 6),
    child: Row(
      children: [
        Expanded(
          child: Text(
            message,
            style: TextStyle(fontSize: 12, color: preset.accentColor),
          ),
        ),
        if (onRetry != null)
          TextButton(
            key: key,
            onPressed: onRetry,
            style: TextButton.styleFrom(foregroundColor: preset.accentColor),
            child: const Text('重试'),
          ),
      ],
    ),
  );

  Widget _classicRow(
    ReaderThemePreset preset,
    ReaderBookmark record,
    int index,
    bool busy,
  ) {
    final deleting = _deleting == record.key;
    final excerpt = record.text.trim();
    return InkWell(
      key: ValueKey('reader-bookmark-${record.key}'),
      onTap: busy ? null : () => Navigator.pop(context, record),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 8, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    record.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: preset.textColor,
                    ),
                  ),
                  if (excerpt.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      excerpt,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.45,
                        color: preset.mutedTextColor,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            IconButton(
              key: ValueKey('reader-bookmark-delete-${record.key}'),
              tooltip: deleting ? '正在删除书签' : '删除书签',
              onPressed: busy
                  ? null
                  : () => unawaited(_delete(context, record)),
              icon: Icon(
                LucideIcons.trash,
                size: 18,
                color: preset.mutedTextColor,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildArchive(BuildContext context) {
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
              controller: _scroll,
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
                        return KeyedSubtree(
                          key: _anchor.keyFor(record.key, index: index),
                          child: JellyTapSurface(
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
