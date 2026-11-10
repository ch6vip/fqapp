import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../services/reader_preferences.dart';
import '../app_ui/app_ui_scope.dart';
import '../wenku/app_search_field.dart';
import '../wenku/wenku_archive.dart';
import '../wenku/wenku_glass.dart';
import 'reader_panel_scroll_anchor.dart';
import 'reader_theme.dart';
import 'settings/reader_settings_widgets.dart';

@immutable
class ReaderFindParagraph {
  const ReaderFindParagraph({required this.start, required this.text});

  /// Global display offset from ReaderChapterLayout.blocks. The caller omits
  /// title and image blocks; offsets therefore need not be contiguous.
  final int start;
  final String text;
}

@immutable
class ReaderFindMatch {
  const ReaderFindMatch({
    required this.start,
    required this.end,
    required this.paragraph,
  });

  /// Global, UTF-16 display offsets; [end] is exclusive.
  final int start;
  final int end;
  final int paragraph;
}

@immutable
class ReaderFindResult {
  ReaderFindResult(List<ReaderFindMatch> matches, {this.truncated = false})
    : matches = List.unmodifiable(matches);

  const ReaderFindResult.empty() : matches = const [], truncated = false;

  final List<ReaderFindMatch> matches;
  final bool truncated;
}

ReaderFindResult _searchParagraphs(
  ({List<ReaderFindParagraph> paragraphs, String query}) input,
) {
  final pattern = RegExp(
    RegExp.escape(input.query),
    caseSensitive: false,
    unicode: true,
  );
  final matches = <ReaderFindMatch>[];
  for (var index = 0; index < input.paragraphs.length; index++) {
    final paragraph = input.paragraphs[index];
    for (final match in pattern.allMatches(paragraph.text)) {
      if (matches.length == 500) {
        return ReaderFindResult(matches, truncated: true);
      }
      matches.add(
        ReaderFindMatch(
          start: paragraph.start + match.start,
          end: paragraph.start + match.end,
          paragraph: index,
        ),
      );
    }
  }
  return ReaderFindResult(matches);
}

/// Literal Unicode case-insensitive chapter search. Work above 64 Ki code units
/// is isolated; title/image filtering and display-to-source mapping stay with
/// the reader engine rather than being duplicated in this UI port.
Future<ReaderFindResult> findInReader(
  List<ReaderFindParagraph> paragraphs,
  String query,
) async {
  final term = query.trim();
  if (term.isEmpty || term.length > 120) {
    return const ReaderFindResult.empty();
  }
  final input = (
    paragraphs: List<ReaderFindParagraph>.of(paragraphs),
    query: term,
  );
  final length = paragraphs.fold<int>(0, (sum, p) => sum + p.text.length);
  return length > 64 * 1024
      ? compute(_searchParagraphs, input)
      : _searchParagraphs(input);
}

/// Ported from Wenku8_Flutter ebcd7f1 lib/reader_find.dart: header, glass search
/// field, sliver spacing and excerpt geometry. Returns a global display match.
class ReaderFindPanel extends StatefulWidget {
  const ReaderFindPanel({
    super.key,
    required this.paragraphs,
    required this.preset,
  });

  final List<ReaderFindParagraph> paragraphs;
  final ReaderThemePreset preset;

  /// Both debounce and explicit submission must wait for the IME to commit.
  static bool isComposing(TextEditingValue value) =>
      value.composing.isValid && !value.composing.isCollapsed;

  @override
  State<ReaderFindPanel> createState() => _ReaderFindPanelState();
}

class _ReaderFindPanelState extends State<ReaderFindPanel> {
  final _query = TextEditingController();
  final _scroll = ScrollController();
  late final _anchor = ReaderPanelScrollAnchor(_scroll);
  Timer? _debounce;
  int _generation = 0;
  bool _searching = false;
  bool _failed = false;
  ReaderFindResult _result = const ReaderFindResult.empty();
  bool? _wasClassic;
  bool _captureScheduled = false;

  @override
  void initState() {
    super.initState();
    _query.addListener(_edited);
    // Row geometry is only safe to read after layout. Capturing on scroll and
    // after builds keeps the anchor fresh for a style switch.
    _scroll.addListener(_scheduleAnchorCapture);
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
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The classic and archive shells are different widget trees, so the
    // result scrollable is remounted on a style switch. Carry the top visible
    // match (and the query, held by `_query`) instead of a raw pixel offset:
    // the header and preview heights differ between the two renderers.
    final classic = AppUiScope.isClassic(context);
    if (_wasClassic != null && _wasClassic != classic) {
      _anchor.restore(
        fallbackOffset: _scroll.hasClients ? _scroll.offset : null,
      );
    }
    _wasClassic = classic;
  }

  @override
  void didUpdateWidget(ReaderFindPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.paragraphs, widget.paragraphs)) _edited();
  }

  void _edited() {
    _debounce?.cancel();
    _generation++;
    final term = _query.text.trim();
    final ready =
        !ReaderFindPanel.isComposing(_query.value) &&
        term.isNotEmpty &&
        term.length <= 120;
    setState(() {
      _failed = false;
      _result = const ReaderFindResult.empty();
      _searching = ready;
    });
    if (ready) {
      _debounce = Timer(const Duration(milliseconds: 180), _search);
    }
  }

  Future<void> _search() async {
    _debounce?.cancel();
    if (ReaderFindPanel.isComposing(_query.value)) return;
    final generation = ++_generation;
    setState(() {
      _searching = true;
      _failed = false;
    });
    try {
      final result = await findInReader(widget.paragraphs, _query.text);
      if (!mounted || generation != _generation) return;
      setState(() {
        _result = result;
        _searching = false;
      });
      if (_scroll.hasClients) _scroll.jumpTo(0);
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _failed = true;
        _searching = false;
      });
    }
  }

  String get _status {
    if (ReaderFindPanel.isComposing(_query.value)) return '完成输入后查找';
    if (_failed) return '查找失败，请重试';
    if (_searching) return '正在查找…';
    if (_query.text.trim().isEmpty) return '仅查找已加载的本章正文，点按结果跳到原文。';
    if (_query.text.trim().length > 120) return '查找文字请控制在 120 字以内';
    if (_result.matches.isEmpty) return '本章没有匹配文字';
    if (_result.truncated) return '显示前 500 处匹配，请缩短查找范围';
    return '${_result.matches.length} 处匹配';
  }

  @override
  void dispose() {
    _generation++;
    _debounce?.cancel();
    _anchor.cancel();
    _scroll.removeListener(_scheduleAnchorCapture);
    _query.dispose();
    _scroll.dispose();
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

  /// Classic: the pre-#291 Material panel — search field, status/retry row,
  /// divider and a plain result list inside the shared reader sheet frame.
  Widget _buildClassic(BuildContext context) {
    final preset = widget.preset;
    return ReaderSettingsSheetFrame(
      preset: preset,
      title: '章内查找',
      closeTooltip: '关闭章内查找',
      scrollKey: const ValueKey('reader-find-scroll'),
      maxHeightFactor: MediaQuery.viewInsetsOf(context).bottom > 0 ? 1 : .78,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 6),
            child: _classicSearchField(preset),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 16, 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _status,
                    key: const ValueKey('reader-find-status'),
                    style: TextStyle(
                      fontSize: 12,
                      color: preset.mutedTextColor,
                    ),
                  ),
                ),
                if (_failed)
                  TextButton(
                    onPressed: _search,
                    style: TextButton.styleFrom(
                      foregroundColor: preset.accentColor,
                    ),
                    child: const Text('重试'),
                  ),
              ],
            ),
          ),
          Divider(height: 1, color: preset.borderColor),
          Expanded(child: _classicResults(preset)),
        ],
      ),
    );
  }

  Widget _classicResults(ReaderThemePreset preset) {
    if (_searching || _failed) return const SizedBox.shrink();
    if (_query.text.trim().isEmpty) {
      return Center(
        child: Text('输入要找的文字', style: TextStyle(color: preset.mutedTextColor)),
      );
    }
    if (_result.matches.isEmpty) {
      return Center(
        child: Text('本章没有匹配文字', style: TextStyle(color: preset.mutedTextColor)),
      );
    }
    return ListView.builder(
      key: const ValueKey('reader-find-results'),
      controller: _scroll,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemCount: _result.matches.length,
      itemBuilder: (context, index) {
        final match = _result.matches[index];
        return KeyedSubtree(
          key: _anchor.keyFor('${match.start}:${match.end}', index: index),
          child: _classicResultRow(context, preset, index),
        );
      },
    );
  }

  Widget _classicSearchField(ReaderThemePreset preset) =>
      ValueListenableBuilder<TextEditingValue>(
        valueListenable: _query,
        builder: (context, value, _) => TextField(
          key: const ValueKey('reader-find-field'),
          controller: _query,
          autofocus: true,
          textInputAction: TextInputAction.search,
          style: TextStyle(color: preset.textColor, fontSize: 14),
          onSubmitted: (_) => _search(),
          decoration: InputDecoration(
            hintText: '查找当前章节文字',
            hintStyle: TextStyle(color: preset.mutedTextColor),
            prefixIcon: Icon(
              LucideIcons.search,
              size: 20,
              color: preset.mutedTextColor,
            ),
            suffixIcon: value.text.isEmpty
                ? null
                : IconButton(
                    tooltip: '清空',
                    color: preset.mutedTextColor,
                    onPressed: () {
                      _query.clear();
                      _edited();
                    },
                    icon: const Icon(LucideIcons.x),
                  ),
            filled: true,
            fillColor: preset.fieldColor,
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 14,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: preset.isEink
                  ? BorderSide(color: preset.borderColor)
                  : BorderSide.none,
            ),
          ),
        ),
      );

  Widget _classicResultRow(
    BuildContext context,
    ReaderThemePreset preset,
    int index,
  ) {
    final match = _result.matches[index];
    final paragraph = widget.paragraphs[match.paragraph];
    final text = paragraph.text;
    final localStart = match.start - paragraph.start;
    final localEnd = match.end - paragraph.start;
    var start = math.max(0, localStart - 24);
    var end = math.min(text.length, localEnd + 56);
    // Do not cut a supplementary character at preview edges.
    if (start > 0 && _isLowSurrogate(text.codeUnitAt(start))) start--;
    if (end < text.length && _isLowSurrogate(text.codeUnitAt(end))) end++;
    return InkWell(
      key: ValueKey('reader-find-result-$index'),
      onTap: () {
        FocusScope.of(context).unfocus();
        Navigator.pop(context, match);
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '第 ${match.paragraph + 1} 段 · 第 ${index + 1} 处',
              style: TextStyle(fontSize: 11, color: preset.mutedTextColor),
            ),
            const SizedBox(height: 4),
            Text.rich(
              TextSpan(
                style: TextStyle(
                  fontSize: 14,
                  height: 1.45,
                  color: preset.textColor,
                ),
                children: [
                  TextSpan(
                    text:
                        '${start > 0 ? '…' : ''}'
                        '${text.substring(start, localStart)}',
                  ),
                  TextSpan(
                    text: text.substring(localStart, localEnd),
                    style: TextStyle(
                      color: preset.accentColor,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  TextSpan(
                    text:
                        '${text.substring(localEnd, end)}'
                        '${end < text.length ? '…' : ''}',
                  ),
                ],
              ),
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildArchive(BuildContext context) => SizedBox(
    height: math.min(520, MediaQuery.sizeOf(context).height * .64),
    child: CustomScrollView(
      key: const ValueKey('reader-find-scroll'),
      primary: false,
      controller: _scroll,
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(24, 8, 14, 8),
          sliver: SliverToBoxAdapter(
            child: Row(
              children: [
                const Expanded(
                  child: ArchiveSection(
                    title: '章内查找',
                    code: 'READER / TEXT QUERY',
                  ),
                ),
                GlassIconButton(
                  icon: CupertinoIcons.xmark,
                  label: '关闭章内查找',
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 14),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AppSearchField(
                  inputKey: const ValueKey('reader-find-field'),
                  controller: _query,
                  hint: '查找当前章节文字',
                  onSubmitted: (_) => _search(),
                ),
                const SizedBox(height: 12),
                Text(
                  _status,
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                if (_failed)
                  GlassTextButton(onPressed: _search, child: const Text('重试')),
              ],
            ),
          ),
        ),
        if (!_searching && !_failed)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 24),
            sliver: SliverList.builder(
              itemCount: _result.matches.length,
              itemBuilder: (context, index) {
                final match = _result.matches[index];
                final paragraph = widget.paragraphs[match.paragraph];
                final text = paragraph.text;
                final localStart = match.start - paragraph.start;
                final localEnd = match.end - paragraph.start;
                var start = math.max(0, localStart - 24);
                var end = math.min(text.length, localEnd + 56);
                // Do not cut a supplementary character at preview edges.
                if (start > 0 && _isLowSurrogate(text.codeUnitAt(start))) {
                  start--;
                }
                if (end < text.length &&
                    _isLowSurrogate(text.codeUnitAt(end))) {
                  end++;
                }
                return KeyedSubtree(
                  key: _anchor.keyFor(
                    '${match.start}:${match.end}',
                    index: index,
                  ),
                  child: JellyTapSurface(
                    key: ValueKey('reader-find-result-$index'),
                    onTap: () {
                      FocusScope.of(context).unfocus();
                      Navigator.pop(context, match);
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 14,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '第 ${match.paragraph + 1} 段 · ${index + 1}',
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 5),
                          Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(
                                  text:
                                      '${start > 0 ? '…' : ''}'
                                      '${text.substring(start, localStart)}',
                                ),
                                TextSpan(
                                  text: text.substring(localStart, localEnd),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                TextSpan(
                                  text:
                                      '${text.substring(localEnd, end)}'
                                      '${end < text.length ? '…' : ''}',
                                ),
                              ],
                            ),
                            maxLines: 4,
                            overflow: TextOverflow.ellipsis,
                          ),
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
  );

  static bool _isLowSurrogate(int unit) => unit >= 0xDC00 && unit <= 0xDFFF;
}
