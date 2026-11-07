import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../services/reader_preferences.dart';
import '../wenku/app_search_field.dart';
import '../wenku/wenku_archive.dart';
import '../wenku/wenku_glass.dart';
import 'reader_theme.dart';

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
  Timer? _debounce;
  int _generation = 0;
  bool _searching = false;
  bool _failed = false;
  ReaderFindResult _result = const ReaderFindResult.empty();

  @override
  void initState() {
    super.initState();
    _query.addListener(_edited);
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
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Theme(
    data: widget.preset.theme(Theme.of(context)),
    child: Builder(
      builder: (context) => SizedBox(
        height: math.min(520, MediaQuery.sizeOf(context).height * .64),
        child: CustomScrollView(
          key: const ValueKey('reader-find-scroll'),
          primary: false,
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
                      GlassTextButton(
                        onPressed: _search,
                        child: const Text('重试'),
                      ),
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
                    return JellyTapSurface(
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
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    ),
  );

  static bool _isLowSurrogate(int unit) => unit >= 0xDC00 && unit <= 0xDFFF;
}
