import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../models/media_item.dart';
import '../../services/reader_full_search.dart';
import '../../services/reader_preferences.dart';
import 'reader_theme.dart';

enum _SearchOrder { combined, mentions, chapter }

/// Classic reader's full-book search. The controller keeps only bounded
/// excerpts; chapters are loaded sequentially through the reader's cache API.
class ReaderFullSearchPanel extends StatefulWidget {
  const ReaderFullSearchPanel({
    super.key,
    required this.chapters,
    required this.loadChapter,
    this.loadChapterForSearch,
    required this.preset,
  });

  final List<Chapter> chapters;
  final ReaderFullSearchLoader loadChapter;
  final ReaderFullSearchCancellableLoader? loadChapterForSearch;
  final ReaderThemePreset preset;

  @override
  State<ReaderFullSearchPanel> createState() => _ReaderFullSearchPanelState();
}

class _ReaderFullSearchPanelState extends State<ReaderFullSearchPanel> {
  final _query = TextEditingController();
  final _scroll = ScrollController();
  late final _networkClock = GestureBinding.instance.samplingClock.stopwatch()
    ..start();
  late final _search = ReaderFullSearchController(
    chapters: widget.chapters,
    loadChapter: widget.loadChapter,
    loadChapterForSearch: widget.loadChapterForSearch,
    networkElapsed: () => _networkClock.elapsed,
  );
  Timer? _debounce;
  _SearchOrder _order = _SearchOrder.combined;
  String _lastQuery = '';
  bool _lastComposing = false;

  bool get _composing =>
      _query.value.composing.isValid && !_query.value.composing.isCollapsed;

  @override
  void initState() {
    super.initState();
    _query.addListener(_edited);
    _search.addListener(_updated);
  }

  void _updated() {
    if (mounted) setState(() {});
  }

  void _edited() {
    // Moving the caret must not restart a full-book network search.
    if (_lastQuery == _query.text && _lastComposing == _composing) return;
    _lastQuery = _query.text;
    _lastComposing = _composing;
    _debounce?.cancel();
    // Clear old rows immediately, including while the IME owns its composition.
    unawaited(_search.search(''));
    if (_scroll.hasClients) _scroll.jumpTo(0);
    if (!_composing &&
        _query.text.trim().isNotEmpty &&
        _query.text.trim().length <= 120) {
      _debounce = Timer(const Duration(milliseconds: 300), _submit);
    }
  }

  void _submit() {
    _debounce?.cancel();
    if (_composing) return;
    unawaited(_search.search(_query.text));
  }

  String get _status {
    final state = _search.state;
    if (_composing) return '完成输入后搜索';
    if (_query.text.trim().isEmpty) return '搜索全书正文，点击结果跳转原文';
    if (_query.text.trim().length > 120) return '搜索文字请控制在 120 字以内';
    if (state.query.isEmpty) return '准备搜索…';
    final scope = '已搜索 ${state.scanned}/${state.total} 章';
    final matches = '${state.matchCount} 处匹配';
    if (state.running) return '$scope · $matches';
    if (state.cancelled) return '已停止 · $scope · $matches';
    if (state.failedChapters.isNotEmpty) {
      return '$scope · $matches · ${state.failedChapters.length} 章未能搜索';
    }
    return '全书 ${state.total} 章 · $matches';
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.removeListener(_updated);
    _search.dispose();
    _networkClock.stop();
    _query.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final preset = widget.preset;
    final state = _search.state;
    final groups = [...state.groups];
    // Combined uses reading order, preserving a stable result list as more
    // chapters arrive. Mentions sorts by the complete count, not visible rows.
    if (_order == _SearchOrder.mentions) {
      groups.sort((a, b) {
        final count = b.count.compareTo(a.count);
        return count != 0 ? count : a.chapterIndex.compareTo(b.chapterIndex);
      });
    }
    final rows = <Object>[];
    for (final group in groups) {
      rows.add(group);
      for (var index = 0; index < group.hits.length; index++) {
        rows.add((group.hits[index], index));
      }
      if (group.truncated) {
        rows.add('本章显示 ${group.hits.length}/${group.count} 处，请细化关键词查看其余结果');
      }
    }
    final height = MediaQuery.sizeOf(context).height;
    return Theme(
      data: preset.theme(Theme.of(context)),
      child: Material(
        color: preset.sheetColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        clipBehavior: Clip.antiAlias,
        // showJellySheet already constrains the surface above the keyboard.
        child: SizedBox(
          height: height * .9,
          child: SafeArea(
            top: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 20, 8, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          key: const ValueKey('reader-full-search-field'),
                          controller: _query,
                          textInputAction: TextInputAction.search,
                          onSubmitted: (_) => _submit(),
                          style: TextStyle(
                            color: preset.textColor,
                            fontSize: 16,
                          ),
                          decoration: InputDecoration(
                            hintText: '搜索全文',
                            labelText: '全文搜索',
                            floatingLabelBehavior: FloatingLabelBehavior.never,
                            filled: true,
                            fillColor: preset.fieldColor,
                            prefixIcon: Icon(
                              Icons.search,
                              color: preset.mutedTextColor,
                            ),
                            suffixIcon: _query.text.isEmpty
                                ? null
                                : IconButton(
                                    tooltip: '清空搜索',
                                    onPressed: _query.clear,
                                    icon: const Icon(Icons.close, size: 20),
                                  ),
                            border: OutlineInputBorder(
                              borderSide: BorderSide.none,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              vertical: 14,
                              horizontal: 12,
                            ),
                          ),
                        ),
                      ),
                      TextButton(
                        key: const ValueKey('reader-full-search-close'),
                        onPressed: () => Navigator.of(context).pop(),
                        style: TextButton.styleFrom(
                          foregroundColor: preset.textColor,
                          minimumSize: const Size(56, 48),
                        ),
                        child: const Text('取消'),
                      ),
                    ],
                  ),
                ),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      for (final order in _SearchOrder.values)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            key: ValueKey(
                              'reader-full-search-order-${order.name}',
                            ),
                            label: Text(switch (order) {
                              _SearchOrder.combined => '综合',
                              _SearchOrder.mentions => '提到最多',
                              _SearchOrder.chapter => '按章节顺序',
                            }),
                            selected: order == _order,
                            selectedColor: preset.accentColor.withValues(
                              alpha: .12,
                            ),
                            labelStyle: TextStyle(
                              color: order == _order
                                  ? preset.accentColor
                                  : preset.textColor,
                            ),
                            onSelected: (_) => setState(() => _order = order),
                          ),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 8, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Semantics(
                          liveRegion: !state.running,
                          child: Text(
                            _status,
                            key: const ValueKey('reader-full-search-status'),
                            style: TextStyle(
                              color: preset.mutedTextColor,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                      if (state.running)
                        TextButton(
                          onPressed: _search.cancel,
                          child: const Text('停止'),
                        )
                      else if (state.cancelled ||
                          state.failedChapters.isNotEmpty)
                        TextButton(
                          onPressed: _submit,
                          child: const Text('重新搜索'),
                        ),
                    ],
                  ),
                ),
                if (state.running)
                  LinearProgressIndicator(
                    minHeight: 2,
                    value: state.total == 0
                        ? null
                        : state.scanned / state.total,
                    color: preset.accentColor,
                  ),
                Expanded(
                  child: rows.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              _emptyMessage,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: preset.mutedTextColor,
                                fontSize: 14,
                              ),
                            ),
                          ),
                        )
                      : ListView.builder(
                          key: const ValueKey('reader-full-search-results'),
                          controller: _scroll,
                          keyboardDismissBehavior:
                              ScrollViewKeyboardDismissBehavior.onDrag,
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                          itemCount: rows.length,
                          itemBuilder: (_, index) => switch (rows[index]) {
                            ReaderFullSearchGroup group => Padding(
                              padding: const EdgeInsets.fromLTRB(4, 22, 4, 10),
                              child: Text(
                                '${group.chapter.title} · ${group.count} 处',
                                style: TextStyle(
                                  color: preset.mutedTextColor,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                            (ReaderFullSearchHit hit, int hitIndex) => _result(
                              context,
                              hit,
                              hitIndex,
                            ),
                            String message => Padding(
                              padding: const EdgeInsets.all(8),
                              child: Text(
                                message,
                                style: TextStyle(
                                  color: preset.mutedTextColor,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                            _ => const SizedBox.shrink(),
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String get _emptyMessage {
    final state = _search.state;
    if (_query.text.trim().isEmpty) return '输入关键词，查找全书内容';
    if (_query.text.trim().length > 120 || _composing) return '';
    if (state.running || state.query.isEmpty) return '正在逐章搜索，可随时停止';
    if (state.cancelled) return '搜索已停止，重新搜索可继续查找全书';
    if (state.failedChapters.isNotEmpty) return '已搜索章节中未找到匹配内容\n部分章节未能加载，请重新搜索';
    return '未找到相关内容，换个关键词试试';
  }

  Widget _result(BuildContext context, ReaderFullSearchHit hit, int index) {
    final preset = widget.preset;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: preset.fieldColor,
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey('reader-full-search-result-${hit.chapterIndex}-$index'),
          onTap: () => Navigator.of(context).pop(hit),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Text.rich(
                TextSpan(
                  style: TextStyle(
                    color: preset.textColor,
                    fontSize: 16,
                    height: 1.65,
                  ),
                  children: [
                    TextSpan(text: hit.excerpt.substring(0, hit.excerptStart)),
                    TextSpan(
                      text: hit.excerpt.substring(
                        hit.excerptStart,
                        hit.excerptEnd,
                      ),
                      style: TextStyle(
                        color: preset.accentColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    TextSpan(text: hit.excerpt.substring(hit.excerptEnd)),
                  ],
                ),
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
