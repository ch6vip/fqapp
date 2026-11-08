import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../../services/ai_reading/ai_chapter_snapshot.dart';
import '../../../services/ai_reading/ai_controller.dart';
import '../../../services/ai_reading/ai_feedback.dart';
import '../../../services/ai_reading/ai_models.dart';
import '../../../services/chapter_cache_store.dart';
import '../../../services/chapter_text_formatter.dart';
import '../../../widgets/home/home_chip.dart';
import '../../../widgets/home/home_design.dart';
import '../../../widgets/home/home_feed_states.dart';
import '../../../widgets/settings/settings_widgets.dart';
import 'ai_feedback_detail_sheet.dart';
import 'ai_feedback_widgets.dart';

/// 全书校对反馈的统一管理页：按章节分组、按状态和类型筛选。
///
/// 章节正文仍在本机缓存里时，页面会用当前正文重建快照；与反馈绑定的
/// 正文哈希不一致就显示「待重新定位」，并禁止编辑内容。
class AiFeedbackManagePage extends StatefulWidget {
  const AiFeedbackManagePage({
    super.key,
    required this.bookId,
    required this.bookTitle,
  });

  final String bookId;
  final String bookTitle;

  @override
  State<AiFeedbackManagePage> createState() => _AiFeedbackManagePageState();
}

enum _StatusFilter {
  all('全部'),
  active('生效中'),
  archived('已归档'),
  relocated('待重新定位'),
  superseded('已被替代'),
  deleted('已删除');

  const _StatusFilter(this.label);

  final String label;
}

enum _CardAction { archive, restore, delete }

class _AiFeedbackManagePageState extends State<AiFeedbackManagePage> {
  List<AiFeedbackAggregate> _aggregates = const [];
  bool _loading = true;
  bool _busy = false;
  String? _error;
  _StatusFilter _status = _StatusFilter.all;
  AiFeedbackKind? _kind;
  Map<String, int> _chapterOrder = const {};
  Map<String, String> _chapterTitles = const {};
  Map<String, AiChapterSnapshot> _snapshots = const {};
  bool _loadingChapters = false;
  bool _selecting = false;
  final _selected = <String>{};

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  List<AiFeedbackCase> get _cases => [
    for (final aggregate in _aggregates) ...aggregate.cases,
  ];

  Future<void> _load({bool quiet = false}) async {
    if (!quiet) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final controller = AiReadingController.instance;
      await controller.init();
      if (!controller.store.isAvailable) {
        throw StateError(controller.store.status ?? 'AI 数据暂不可用');
      }
      final aggregates = await AiFeedbackService.instance.aggregatesForBook(
        widget.bookId,
      );
      if (!mounted) return;
      setState(() {
        _aggregates = aggregates;
        _loading = false;
        _error = null;
      });
      if (!quiet || _chapterOrder.isEmpty) {
        unawaited(_loadChapters());
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        if (!quiet) _error = '读取反馈失败：$error';
      });
      if (quiet) _snack('刷新失败：$error');
    }
  }

  /// 章节标题和顺序来自本机目录缓存；正文用来判断反馈绑定的版本是否
  /// 仍然是当前版本。任何一步失败都只影响展示，不影响反馈本身。
  Future<void> _loadChapters() async {
    final chapterIds = {
      for (final aggregate in _aggregates) aggregate.chapterId,
    };
    setState(() => _loadingChapters = true);
    CachedBook? book;
    try {
      final store = ChapterCacheStore.instance;
      book = await store.savedCatalogue(widget.bookId);
      book ??= await store.cachedBook(widget.bookId);
    } catch (_) {
      book = null;
    }
    if (book == null) {
      if (mounted) setState(() => _loadingChapters = false);
      return;
    }
    final order = <String, int>{};
    final titles = <String, String>{};
    for (var i = 0; i < book.chapters.length; i++) {
      final chapter = book.chapters[i];
      order[chapter.itemId] = i;
      titles[chapter.itemId] = chapter.title.trim();
    }
    final snapshots = <String, AiChapterSnapshot>{..._snapshots};
    // 规范正文哈希会把与章节标题相同的第一段排除在外，没有标题重建出来
    // 的哈希会假性失配，所以这一章宁可不建快照。
    for (final chapterId in chapterIds) {
      final title = titles[chapterId];
      if (title == null || title.isEmpty) continue;
      try {
        final text = await ChapterCacheStore.instance.read(
          bookId: widget.bookId,
          chapterId: chapterId,
        );
        if (text == null || text.trim().isEmpty) continue;
        snapshots[chapterId] = AiChapterSnapshotBuilder.fromContent(
          ChapterContent.fromCacheText(text),
          title,
        );
      } catch (_) {
        // 正文不可解析或没有缓存：卡片继续可看可归档，只是打不开详情。
      }
    }
    if (!mounted) return;
    setState(() {
      _chapterOrder = order;
      _chapterTitles = titles;
      _snapshots = snapshots;
      _loadingChapters = false;
    });
  }

  /// 归档 / 被替代 / 删除的反馈已经退出显示保护，卡片上不能继续写
  /// 「此处已锁定」，避免把历史记录误当成当前生效规则。
  String _protectionSummary(AiFeedbackCase feedback) {
    if (feedback.status != AiFeedbackStatus.active) {
      return aiFeedbackStatusText(feedback.status);
    }
    return aiFeedbackProtectionSummary(feedback);
  }

  bool _relocated(AiFeedbackCase feedback) {
    final snapshot = _snapshots[feedback.chapterId];
    return snapshot != null && snapshot.canonicalHash != feedback.canonicalHash;
  }

  bool _matches(AiFeedbackCase feedback) {
    if (_kind != null && feedback.kind != _kind) return false;
    final relocated = _relocated(feedback);
    return switch (_status) {
      _StatusFilter.all => feedback.status != AiFeedbackStatus.deleted,
      _StatusFilter.active =>
        feedback.status == AiFeedbackStatus.active && !relocated,
      _StatusFilter.archived => feedback.status == AiFeedbackStatus.archived,
      _StatusFilter.relocated =>
        feedback.status == AiFeedbackStatus.active && relocated,
      _StatusFilter.superseded =>
        feedback.status == AiFeedbackStatus.superseded,
      _StatusFilter.deleted => feedback.status == AiFeedbackStatus.deleted,
    };
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  String _chapterLabel(String chapterId) {
    final title = _chapterTitles[chapterId];
    if (title != null && title.isNotEmpty) return title;
    final index = _chapterOrder[chapterId];
    if (index != null) return '第${index + 1}章';
    return _loadingChapters ? '正在读取章节…' : '章节 $chapterId';
  }

  /// 打开详情前再试一次读缓存：章节可能在进入本页之后才被重新缓存。
  Future<AiChapterSnapshot?> _snapshotFor(AiFeedbackCase feedback) async {
    final cached = _snapshots[feedback.chapterId];
    if (cached != null) return cached;
    final title = _chapterTitles[feedback.chapterId];
    if (title == null || title.isEmpty) return null;
    try {
      final text = await ChapterCacheStore.instance.read(
        bookId: widget.bookId,
        chapterId: feedback.chapterId,
      );
      if (text == null || text.trim().isEmpty) return null;
      final snapshot = AiChapterSnapshotBuilder.fromContent(
        ChapterContent.fromCacheText(text),
        title,
      );
      if (mounted) {
        setState(() {
          _snapshots = {..._snapshots, feedback.chapterId: snapshot};
        });
      }
      return snapshot;
    } catch (_) {
      return null;
    }
  }

  Future<void> _openDetail(AiFeedbackCase feedback) async {
    final snapshot =
        _snapshots[feedback.chapterId] ?? await _snapshotFor(feedback);
    if (!mounted) return;
    if (snapshot == null) {
      _snack('本章正文没有缓存，无法打开详情；可用右侧菜单归档或删除。');
      return;
    }
    await showAiFeedbackDetailSheet(
      context,
      feedback: feedback,
      snapshot: snapshot,
      onChanged: () => unawaited(_load(quiet: true)),
    );
  }

  void _toggleSelection(AiFeedbackCase feedback) {
    setState(() {
      if (!_selected.add(feedback.feedbackId)) {
        _selected.remove(feedback.feedbackId);
      }
    });
  }

  Future<void> _bulk(AiFeedbackStatus status) async {
    if (_busy || _selected.isEmpty) return;
    final cases = _cases
        .where((feedback) => _selected.contains(feedback.feedbackId))
        .toList(growable: false);
    setState(() => _busy = true);
    var done = 0;
    try {
      for (final feedback in cases) {
        await AiFeedbackService.instance.setStatus(
          feedback: feedback,
          status: status,
        );
        done++;
      }
      if (mounted) {
        setState(() {
          _selected.clear();
          _selecting = false;
        });
        _snack('已处理 $done 条');
      }
      await _load(quiet: true);
    } catch (error) {
      _snack('批量操作在 $done 条后失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _bulkDelete() async {
    if (_busy || _selected.isEmpty) return;
    final confirmed = await showSettingsConfirmDialog(
      context: context,
      title: '删除选中的 ${_selected.length} 条反馈？',
      message: '删除后不再参与试验，可以从「已删除」筛选里恢复。',
      confirmLabel: '删除',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    final cases = _cases
        .where((feedback) => _selected.contains(feedback.feedbackId))
        .toList(growable: false);
    setState(() => _busy = true);
    var done = 0;
    try {
      for (final feedback in cases) {
        await AiFeedbackService.instance.deleteCase(feedback);
        done++;
      }
      if (mounted) {
        setState(() {
          _selected.clear();
          _selecting = false;
        });
        _snack('已删除 $done 条，可恢复');
      }
      await _load(quiet: true);
    } catch (error) {
      _snack('批量删除在 $done 条后失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _onCardAction(
    AiFeedbackCase feedback,
    _CardAction action,
  ) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      switch (action) {
        case _CardAction.archive:
          await AiFeedbackService.instance.setStatus(
            feedback: feedback,
            status: AiFeedbackStatus.archived,
          );
          _snack('已归档');
        case _CardAction.restore:
          await AiFeedbackService.instance.setStatus(
            feedback: feedback,
            status: AiFeedbackStatus.active,
          );
          _snack('已恢复');
        case _CardAction.delete:
          final confirmed = await showSettingsConfirmDialog(
            context: context,
            title: '删除这条反馈？',
            message: '删除后不再参与试验，可以从「已删除」筛选里恢复。',
            confirmLabel: '删除',
            destructive: true,
          );
          if (!confirmed || !mounted) return;
          await AiFeedbackService.instance.deleteCase(feedback);
          _snack('已删除，可恢复');
      }
      await _load(quiet: true);
    } catch (error) {
      _snack('操作失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return SettingsScaffold(
      title: _selecting ? '已选 ${_selected.length} 条' : '校对反馈',
      actions: [
        TextButton(
          onPressed: _busy
              ? null
              : () => setState(() {
                  _selecting = !_selecting;
                  if (!_selecting) _selected.clear();
                }),
          child: Text(_selecting ? '取消' : '批量'),
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
                      onPressed: _selected.isEmpty || _busy
                          ? null
                          : () => _bulk(AiFeedbackStatus.archived),
                      child: const Text('归档'),
                    ),
                    TextButton(
                      onPressed: _selected.isEmpty || _busy
                          ? null
                          : () => _bulk(AiFeedbackStatus.active),
                      child: const Text('恢复'),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: _selected.isEmpty || _busy
                          ? null
                          : _bulkDelete,
                      child: const Text('删除'),
                    ),
                  ],
                ),
              ),
            )
          : null,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? HomeStateView(
              icon: LucideIcons.triangle_alert,
              title: '读取失败',
              message: _error,
              actionLabel: '重试',
              onAction: () => unawaited(_load()),
            )
          : Column(
              children: [
                _header(palette),
                Expanded(child: _list(palette)),
              ],
            ),
    );
  }

  Widget _header(HomePalette palette) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _chipRow([
            for (final status in _StatusFilter.values)
              HomeChip(
                label: status.label,
                selected: _status == status,
                onTap: () => setState(() => _status = status),
              ),
          ]),
          const SizedBox(height: 2),
          _chipRow([
            HomeChip(
              label: '全部类型',
              selected: _kind == null,
              onTap: () => setState(() => _kind = null),
            ),
            for (final kind in AiFeedbackKind.values)
              HomeChip(
                label: kind.label,
                selected: _kind == kind,
                onTap: () => setState(() => _kind = kind),
              ),
          ]),
        ],
      ),
    );
  }

  Widget _chipRow(List<Widget> chips) => SizedBox(
    height: HomeChip.minTapTarget,
    child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: EdgeInsets.zero,
      child: Row(
        children: [
          for (var i = 0; i < chips.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            Center(child: chips[i]),
          ],
        ],
      ),
    ),
  );

  Widget _list(HomePalette palette) {
    final cases = _cases.where(_matches).toList(growable: false);
    if (cases.isEmpty) {
      final emptyBook = _cases.isEmpty;
      return RefreshIndicator(
        onRefresh: () => _load(quiet: true),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.only(top: 8),
          children: [
            HomeStateView(
              icon: emptyBook
                  ? LucideIcons.message_square
                  : LucideIcons.search_x,
              title: emptyBook ? '还没有校对反馈' : '没有符合条件的反馈',
              message: emptyBook ? '阅读时给 AI 修改或选区添加反馈。' : '换个筛选条件试试。',
            ),
          ],
        ),
      );
    }
    final groups = _groupByChapter(cases);
    final children = <Widget>[];
    for (final group in groups) {
      children.add(_chapterHeader(palette, group));
      for (final feedback in group.cases) {
        children.add(_card(palette, feedback));
      }
    }
    return RefreshIndicator(
      onRefresh: () => _load(quiet: true),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        children: children,
      ),
    );
  }

  List<_ChapterGroup> _groupByChapter(List<AiFeedbackCase> cases) {
    final grouped = <String, List<AiFeedbackCase>>{};
    for (final feedback in cases) {
      (grouped[feedback.chapterId] ??= []).add(feedback);
    }
    final groups = [
      for (final entry in grouped.entries)
        _ChapterGroup(chapterId: entry.key, cases: entry.value),
    ];
    groups.sort((a, b) {
      final left = _chapterOrder[a.chapterId];
      final right = _chapterOrder[b.chapterId];
      if (left != null && right != null) return left.compareTo(right);
      if (left != null) return -1;
      if (right != null) return 1;
      return b.latest.compareTo(a.latest);
    });
    return groups;
  }

  Widget _chapterHeader(HomePalette palette, _ChapterGroup group) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 14, 4, 8),
    child: Row(
      children: [
        Expanded(
          child: Text(
            _chapterLabel(group.chapterId),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              height: 1.3,
              fontWeight: FontWeight.w600,
              color: palette.muted,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          '${group.cases.length} 条',
          style: TextStyle(fontSize: 12, color: palette.muted),
        ),
      ],
    ),
  );

  Widget _card(HomePalette palette, AiFeedbackCase feedback) {
    final relocated = _relocated(feedback);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: palette.surface,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: palette.line, width: 0.6),
        ),
        child: InkWell(
          onTap: _selecting
              ? () => _toggleSelection(feedback)
              : () => unawaited(_openDetail(feedback)),
          onLongPress: _selecting
              ? null
              : () {
                  setState(() {
                    _selecting = true;
                    _selected.add(feedback.feedbackId);
                  });
                },
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 6, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (_selecting)
                      Checkbox(
                        value: _selected.contains(feedback.feedbackId),
                        onChanged: (_) => _toggleSelection(feedback),
                      )
                    else
                      const SizedBox(width: 4),
                    AiFeedbackKindBadge(kind: feedback.kind),
                    const Spacer(),
                    Text(
                      aiFeedbackTimeLabel(feedback.updatedAt),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: palette.muted),
                    ),
                    if (!_selecting)
                      PopupMenuButton<_CardAction>(
                        tooltip: '更多操作',
                        icon: Icon(
                          LucideIcons.ellipsis_vertical,
                          size: 18,
                          color: palette.muted,
                        ),
                        padding: EdgeInsets.zero,
                        color: palette.surface,
                        onSelected: (action) =>
                            unawaited(_onCardAction(feedback, action)),
                        itemBuilder: (context) => [
                          if (feedback.status == AiFeedbackStatus.active ||
                              feedback.status == AiFeedbackStatus.superseded)
                            const PopupMenuItem(
                              value: _CardAction.archive,
                              child: Text('归档'),
                            ),
                          if (feedback.status == AiFeedbackStatus.archived ||
                              feedback.status == AiFeedbackStatus.deleted)
                            const PopupMenuItem(
                              value: _CardAction.restore,
                              child: Text('恢复'),
                            ),
                          if (feedback.status != AiFeedbackStatus.deleted)
                            const PopupMenuItem(
                              value: _CardAction.delete,
                              child: Text('删除'),
                            ),
                        ],
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  feedback.anchor.sourceText,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.5,
                    color: palette.ink,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _editSummary(feedback),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.45,
                    color: palette.muted,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    AiFeedbackStatusPill(
                      feedback: feedback,
                      relocated: relocated,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _protectionSummary(feedback),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.right,
                        style: TextStyle(fontSize: 12, color: palette.muted),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _compactChange(String before, String after) {
    var prefix = 0;
    while (prefix < before.length &&
        prefix < after.length &&
        before.codeUnitAt(prefix) == after.codeUnitAt(prefix)) {
      prefix++;
    }
    var suffix = 0;
    while (suffix < before.length - prefix &&
        suffix < after.length - prefix &&
        before.codeUnitAt(before.length - suffix - 1) ==
            after.codeUnitAt(after.length - suffix - 1)) {
      suffix++;
    }
    final left = before.substring(prefix, before.length - suffix);
    final right = after.substring(prefix, after.length - suffix);
    return '${left.isEmpty ? '∅' : left} → ${right.isEmpty ? '∅' : right}';
  }

  String _editSummary(AiFeedbackCase feedback) {
    final observation = feedback.originalObservation;
    final replacement = observation?['replacement'];
    final expected = feedback.assertion.expectedText?.trim() ?? '';
    return switch (feedback.kind) {
      AiFeedbackKind.good =>
        replacement is String && replacement.isNotEmpty
            ? '改法：${_compactChange(feedback.anchor.sourceText, replacement)}'
            : '已认可 AI 改法',
      AiFeedbackKind.shouldNotChange =>
        replacement is String && replacement.isNotEmpty
            ? '原文保留；AI 曾改为 $replacement'
            : '原文保留',
      AiFeedbackKind.wrongChange =>
        expected.isNotEmpty ? '期望：$expected' : '标记为改错',
      AiFeedbackKind.missedChange =>
        expected.isNotEmpty ? '期望：$expected' : '标记为漏改',
    };
  }
}

class _ChapterGroup {
  _ChapterGroup({required this.chapterId, required this.cases});

  final String chapterId;
  final List<AiFeedbackCase> cases;

  late final DateTime latest = cases
      .map((feedback) => feedback.updatedAt)
      .reduce((a, b) => a.isAfter(b) ? a : b);
}
