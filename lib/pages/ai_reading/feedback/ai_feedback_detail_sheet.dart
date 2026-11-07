import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../../services/ai_reading/ai_feedback.dart';
import '../../../services/ai_reading/ai_models.dart';
import '../../../services/chapter_cache_store.dart';
import '../../../widgets/ai_reading/ai_ui.dart';
import '../../../widgets/home/home_design.dart';
import '../../../widgets/home/home_sheet.dart';
import '../../../widgets/settings/settings_widgets.dart';
import 'ai_feedback_widgets.dart';

/// 打开一条反馈的详情面板。面板里的每一次成功修改都会回调 [onChanged]，
/// 调用方据此重新加载书籍统计。
Future<void> showAiFeedbackDetailSheet(
  BuildContext context, {
  required AiFeedbackCase feedback,
  required AiChapterSnapshot snapshot,
  VoidCallback? onChanged,
}) {
  final palette = HomePalette.of(context);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: homeSheetColor(palette),
    clipBehavior: Clip.antiAlias,
    shape: homeSheetShape(palette, top: HomeSheetFrame.radius),
    builder: (_) => AiFeedbackDetailSheet(
      feedback: feedback,
      snapshot: snapshot,
      onChanged: onChanged,
    ),
  );
}

/// 反馈详情：原文锚点、断言、修订记录、保护开关和生命周期操作。
///
/// [snapshot] 必须是这条反馈绑定的正文版本；版本不一致时更新会写进另一个
/// 章节快照，所以这里显式拒绝编辑，只保留归档、删除等按反馈自身版本执行
/// 的操作。
class AiFeedbackDetailSheet extends StatefulWidget {
  const AiFeedbackDetailSheet({
    super.key,
    required this.feedback,
    required this.snapshot,
    this.onChanged,
  });

  final AiFeedbackCase feedback;
  final AiChapterSnapshot snapshot;
  final VoidCallback? onChanged;

  @override
  State<AiFeedbackDetailSheet> createState() => _AiFeedbackDetailSheetState();
}

class _AiFeedbackDetailSheetState extends State<AiFeedbackDetailSheet> {
  late AiFeedbackCase _case;
  List<AiFeedbackProtection> _protections = const [];
  bool _busy = false;
  String? _notice;
  bool _noticeIsError = false;
  bool _techOpen = false;
  String? _chapterTitle;
  int? _chapterIndex;

  @override
  void initState() {
    super.initState();
    _case = widget.feedback;
    unawaited(_refresh());
    unawaited(_loadChapterLabel());
  }

  bool get _versionMatches =>
      _case.canonicalHash == widget.snapshot.canonicalHash &&
      _case.canonicalVersion == widget.snapshot.canonicalVersion;

  bool get _protects => aiFeedbackProtects(_case);

  /// 只有「当前正文版本 + 生效中」的反馈才能改内容。归档或删除状态下
  /// 更新会顺带重建保护，所以先恢复再编辑。
  bool get _canEdit =>
      _versionMatches && _case.status == AiFeedbackStatus.active;

  String? get _editBlockedReason {
    if (!_versionMatches) return '原文版本已变化，暂时不能编辑内容';
    if (_case.status != AiFeedbackStatus.active) return '先恢复这条反馈才能编辑';
    return null;
  }

  AiFeedbackProtection? get _latestProtection {
    AiFeedbackProtection? latest;
    for (final protection in _protections) {
      if (latest == null || protection.updatedAt.isAfter(latest.updatedAt)) {
        latest = protection;
      }
    }
    return latest;
  }

  Future<void> _refresh() async {
    try {
      final aggregate = await AiFeedbackService.instance.aggregateForChapter(
        bookId: _case.bookId,
        chapterId: _case.chapterId,
        canonicalVersion: _case.canonicalVersion,
        canonicalHash: _case.canonicalHash,
      );
      if (!mounted) return;
      setState(() {
        _protections = aggregate == null
            ? const []
            : aggregate.protections
                  .where((p) => p.sourceFeedbackId == _case.feedbackId)
                  .toList(growable: false);
        for (final current in aggregate?.cases ?? const <AiFeedbackCase>[]) {
          if (current.feedbackId == _case.feedbackId) {
            _case = current;
            break;
          }
        }
      });
    } catch (error) {
      _setNotice('读取保护状态失败：$error', error: true);
    }
  }

  Future<void> _loadChapterLabel() async {
    CachedBook? book;
    try {
      final store = ChapterCacheStore.instance;
      book = await store.savedCatalogue(_case.bookId);
      book ??= await store.cachedBook(_case.bookId);
    } catch (_) {
      book = null;
    }
    if (book == null) return;
    final index = book.chapters.indexWhere(
      (chapter) => chapter.itemId == _case.chapterId,
    );
    if (index < 0 || !mounted) return;
    setState(() {
      _chapterIndex = index;
      final title = book!.chapters[index].title.trim();
      _chapterTitle = title.isEmpty ? null : title;
    });
  }

  void _setNotice(String message, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _notice = message;
      _noticeIsError = error;
    });
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _run(Future<void> Function() action, {String? success}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      await action();
      widget.onChanged?.call();
      await _refresh();
      if (success != null) _setNotice(success);
    } on AiFeedbackConflict catch (error) {
      _setNotice(error.message, error: true);
      _snack(error.message);
    } catch (error) {
      _setNotice('操作失败：$error', error: true);
      _snack('操作失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _editComment() async {
    final blocked = _editBlockedReason;
    if (blocked != null) {
      _setNotice(blocked, error: true);
      return;
    }
    final text = await showAiTextInputDialog(
      context,
      title: '补充说明',
      hint: '例如：同音字，这里想表达坚持不住',
      initial: _case.comment,
      maxLines: 3,
    );
    if (text == null || !mounted || text == _case.comment) return;
    await _run(() async {
      await AiFeedbackService.instance.updateCase(
        currentCase: _case,
        snapshot: widget.snapshot,
        comment: text,
      );
    }, success: '补充说明已保存');
  }

  Future<void> _editExpected() async {
    final blocked = _editBlockedReason;
    if (blocked != null) {
      _setNotice(blocked, error: true);
      return;
    }
    final current = _case.assertion.expectedText ?? '';
    final text = await showAiTextInputDialog(
      context,
      title: '期望文本',
      hint: '留空表示只记为需要人工确认',
      initial: current,
      maxLines: 3,
    );
    if (text == null || !mounted || text == current) return;
    await _run(() async {
      await AiFeedbackService.instance.updateCase(
        currentCase: _case,
        snapshot: widget.snapshot,
        expectedText: text,
      );
    }, success: '期望文本已保存');
  }

  Future<void> _reanchor() async {
    if (_busy) return;
    final text = _case.anchor.sourceText;
    if (text.isEmpty) {
      _setNotice('这条反馈没有可用的原文片段，无法自动重新定位', error: true);
      return;
    }
    final positions = <int>[];
    var from = 0;
    while (true) {
      final index = widget.snapshot.requestText.indexOf(text, from);
      if (index < 0) break;
      positions.add(index);
      from = index + text.length;
    }
    if (positions.isEmpty) {
      _setNotice('当前正文找不到这段原文，请保留为历史或手动重新添加反馈', error: true);
      return;
    }
    var selected = positions.first;
    if (positions.length > 1) {
      final chosen = await showDialog<int>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('选择新的原文位置'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final start in positions)
                  ListTile(
                    title: Text(
                      widget.snapshot.requestText.substring(
                        (start - 16).clamp(
                          0,
                          widget.snapshot.requestText.length,
                        ),
                        (start + text.length + 16).clamp(
                          0,
                          widget.snapshot.requestText.length,
                        ),
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () => Navigator.pop(context, start),
                  ),
              ],
            ),
          ),
        ),
      );
      if (chosen == null || !mounted) return;
      selected = chosen;
    }
    final confirmed = await showSettingsConfirmDialog(
      context: context,
      title: '重新定位这条反馈？',
      message: '只更新这条反馈和它的保护锚点，历史修订保留；不会自动套用到其它章节。',
      confirmLabel: '重新定位',
    );
    if (!confirmed || !mounted) return;
    final start = selected;
    final end = start + text.length;
    await _run(() async {
      final updated = await AiFeedbackService.instance.reanchorCase(
        feedback: _case,
        snapshot: widget.snapshot,
        sourceStart: start,
        sourceEnd: end,
      );
      if (mounted) setState(() => _case = updated);
    }, success: '已重新定位到当前正文');
  }

  Future<void> _changeKind(AiFeedbackKind kind) async {
    if (_busy || kind == _case.kind) return;
    final blocked = _editBlockedReason;
    if (blocked != null) {
      _setNotice(blocked, error: true);
      return;
    }
    if (kind == AiFeedbackKind.good && _case.originalObservation == null) {
      _setNotice('「改得好」必须来自一条已验证的 AI 修改', error: true);
      return;
    }
    final previous = _case.kind;
    final changesProtection =
        kind == AiFeedbackKind.good ||
        kind == AiFeedbackKind.shouldNotChange ||
        previous == AiFeedbackKind.good ||
        previous == AiFeedbackKind.shouldNotChange;
    if (changesProtection) {
      final message = switch (kind) {
        AiFeedbackKind.good => '改成「改得好」会把当时认可的改法锁定为显示结果，与它重叠的新 AI 修改会整条跳过。',
        AiFeedbackKind.shouldNotChange => '改成「不该改」会锁定这段原文，与它重叠的新 AI 修改会整条跳过。',
        _ => '改成「${kind.label}」会撤销这条反馈当前的显示保护。',
      };
      final confirmed = await showSettingsConfirmDialog(
        context: context,
        title: '改成「${kind.label}」？',
        message: message,
        confirmLabel: '修改',
      );
      if (!confirmed || !mounted) return;
    }
    await _run(() async {
      await AiFeedbackService.instance.updateCase(
        currentCase: _case,
        snapshot: widget.snapshot,
        kind: kind,
      );
    }, success: '反馈类型已改为「${kind.label}」');
  }

  Future<void> _toggleProtection(bool enabled) async {
    final blocked = _editBlockedReason;
    if (blocked != null) {
      _setNotice(blocked, error: true);
      return;
    }
    await _run(
      () => AiFeedbackService.instance.setProtectionEnabled(
        feedback: _case,
        enabled: enabled,
      ),
      success: enabled ? '显示保护已启用' : '显示保护已停用',
    );
  }

  Future<void> _archive() async {
    final message = _protects && _case.protectionEnabled
        ? '归档后不再参与试验，并会停用这条反馈的显示保护，可以随时恢复。'
        : '归档后不再参与试验，可以随时恢复。';
    final confirmed = await showSettingsConfirmDialog(
      context: context,
      title: '归档这条反馈？',
      message: message,
      confirmLabel: '归档',
    );
    if (!confirmed || !mounted) return;
    await _run(
      () => AiFeedbackService.instance.setStatus(
        feedback: _case,
        status: AiFeedbackStatus.archived,
      ),
      success: '已归档',
    );
  }

  Future<void> _restore() async {
    await _run(
      () => AiFeedbackService.instance.setStatus(
        feedback: _case,
        status: AiFeedbackStatus.active,
      ),
      success: '已恢复',
    );
  }

  Future<void> _deleteSoft() async {
    final confirmed = await showSettingsConfirmDialog(
      context: context,
      title: '删除这条反馈？',
      message: '删除后不再参与试验，可以从「已删除」筛选里恢复。',
      confirmLabel: '删除',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    await _run(
      () => AiFeedbackService.instance.deleteCase(_case),
      success: '已删除，可恢复',
    );
  }

  Future<void> _deletePermanent() async {
    final first = await showSettingsConfirmDialog(
      context: context,
      title: '永久删除这条反馈？',
      message: '永久删除会连同它的保护记录一起清除，无法在应用内恢复。',
      confirmLabel: '永久删除',
      destructive: true,
    );
    if (!first || !mounted) return;
    final second = await showSettingsConfirmDialog(
      context: context,
      title: '再次确认永久删除',
      message: '备份文件里可能仍有旧副本，但本机无法恢复这条反馈。',
      confirmLabel: '永久删除',
      destructive: true,
    );
    if (!second || !mounted) return;
    await _run(
      () => AiFeedbackService.instance.deleteCase(_case, permanent: true),
      success: null,
    );
    if (!mounted) return;
    Navigator.of(context).maybePop();
  }

  String get _chapterText {
    final title = _chapterTitle;
    if (title != null) return title;
    final index = _chapterIndex;
    if (index != null) return '第${index + 1}章';
    return _case.chapterId;
  }

  String get _approvedReplacement {
    final observation = _case.originalObservation;
    final replacement = observation?['replacement'];
    return replacement is String ? replacement : '';
  }

  /// 保护当前生效时，阅读器在这段区间里显示的结果。
  String? get _lockedText {
    final protection = _latestProtection;
    if (protection == null || !protection.isActive) return null;
    if (protection.policy == AiProtectionPolicy.keepOriginal) {
      return _case.anchor.sourceText;
    }
    final replacement = protection.approvedEdit?.replacement;
    if (replacement != null && replacement.isNotEmpty) return replacement;
    final approved = _approvedReplacement;
    if (approved.isNotEmpty) return approved;
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final relocated = !_versionMatches;
    final approved = _approvedReplacement;
    final expected = _case.assertion.expectedText?.trim() ?? '';
    return HomeSheetFrame(
      title: '反馈详情',
      maxHeightFactor: 0.9,
      children: [
        Row(
          children: [
            AiFeedbackKindBadge(kind: _case.kind),
            const SizedBox(width: 6),
            AiFeedbackStatusPill(feedback: _case, relocated: relocated),
            const SizedBox(width: 8),
            Expanded(
              child: Align(
                alignment: Alignment.centerRight,
                child: Text(
                  aiFeedbackTimeLabel(_case.updatedAt),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: palette.muted),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (relocated) ...[
          AiInfoCard(
            title: '原文版本已变化',
            body: '正文已变化；可以按原文片段重新定位，或归档/删除。',
            icon: LucideIcons.triangle_alert,
            tone: AiStatusTone.warn,
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _busy ? null : _reanchor,
            icon: const Icon(LucideIcons.crosshair, size: 16),
            label: const Text('重新定位'),
          ),
          const SizedBox(height: 10),
        ],
        AiQuoteBlock(label: '原文', text: _case.anchor.sourceText, maxLines: 6),
        if (approved.isNotEmpty && approved != _case.anchor.sourceText) ...[
          const SizedBox(height: 8),
          AiQuoteBlock(label: 'AI 改为', text: approved, maxLines: 6),
        ],
        if (_lockedText case final locked?) ...[
          const SizedBox(height: 8),
          AiQuoteBlock(label: '当前显示', text: locked, maxLines: 6),
        ],
        const SizedBox(height: 12),
        SettingsGroupCard(
          children: [
            _FieldRow(
              title: '章节',
              subtitle: '正文版本 ${_case.canonicalVersion}',
              value: _chapterText,
            ),
            _kindPicker(palette),
            if (_case.kind == AiFeedbackKind.good)
              _FieldRow(
                title: '认可改法',
                value: approved.isEmpty ? '未记录' : approved,
              )
            else if (_case.kind == AiFeedbackKind.shouldNotChange)
              const _FieldRow(title: '期望结果', subtitle: '保持原文', value: '保持原文')
            else
              _FieldRow(
                title: '期望文本',
                value: expected.isEmpty ? '未填写' : expected,
                onTap: _canEdit && !_busy ? _editExpected : null,
              ),
            _FieldRow(
              title: '补充说明',
              value: _case.comment.isEmpty ? '未填写' : _case.comment,
              onTap: _canEdit && !_busy ? _editComment : null,
            ),
          ],
        ),
        const SizedBox(height: 12),
        SettingsGroupCard(
          children: [
            if (_protects)
              SettingsRow(
                title: '显示保护',
                trailing: SettingsSwitch(
                  value: _latestProtection?.isActive ?? _case.protectionEnabled,
                  semanticLabel: '显示保护',
                  onChanged: _canEdit && !_busy ? _toggleProtection : null,
                ),
              )
            else
              const SettingsRow(title: '显示保护', subtitle: '只作为回归用例', value: '无'),
          ],
        ),
        const SizedBox(height: 14),
        const SettingsSectionHeader(title: '修改历史'),
        const SizedBox(height: 8),
        SettingsGroupCard(
          children: _case.history.isEmpty
              ? [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                    child: Text(
                      '暂无修订记录',
                      style: TextStyle(fontSize: 12.5, color: palette.muted),
                    ),
                  ),
                ]
              : [
                  for (final entry in _case.history)
                    _historyRow(entry, palette),
                ],
        ),
        if (_notice != null) ...[
          const SizedBox(height: 12),
          _noticeRow(_noticeIsError, palette),
        ],
        const SizedBox(height: 14),
        _actions(palette),
        const SizedBox(height: 6),
        TextButton.icon(
          key: const ValueKey('ai_feedback_tech_toggle'),
          onPressed: () => setState(() => _techOpen = !_techOpen),
          icon: Icon(
            _techOpen ? LucideIcons.chevron_up : LucideIcons.chevron_down,
            size: 16,
          ),
          label: Text(_techOpen ? '收起技术详情' : '技术详情'),
        ),
        if (_techOpen) _technicalDetails(palette),
      ],
    );
  }

  Widget _kindPicker(HomePalette palette) {
    return PopupMenuButton<AiFeedbackKind>(
      enabled: _canEdit && !_busy,
      tooltip: '修改反馈类型',
      color: palette.surface,
      padding: EdgeInsets.zero,
      onSelected: _changeKind,
      itemBuilder: (context) => [
        for (final kind in AiFeedbackKind.values)
          PopupMenuItem<AiFeedbackKind>(
            value: kind,
            child: Row(
              children: [
                SizedBox(
                  width: 18,
                  child: kind == _case.kind
                      ? Icon(LucideIcons.check, size: 16, color: palette.ink)
                      : null,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        kind.label,
                        style: TextStyle(fontSize: 14, color: palette.ink),
                      ),
                      Text(
                        aiFeedbackKindDescription(kind),
                        style: TextStyle(fontSize: 12, color: palette.muted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
      child: SettingsRow(
        title: '反馈类型',
        value: _case.kind.label,
        showChevron: true,
      ),
    );
  }

  Widget _historyRow(AiFeedbackHistoryEntry entry, HomePalette palette) {
    final expected = entry.assertion.expectedText?.trim() ?? '';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'v${entry.revision}',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: palette.ink,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${entry.kind.label}，${aiFeedbackStatusText(entry.status)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, color: palette.muted),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                aiFeedbackTimeLabel(entry.changedAt),
                style: TextStyle(fontSize: 12, color: palette.muted),
              ),
            ],
          ),
          if (entry.comment.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              '说明：${entry.comment}',
              style: TextStyle(fontSize: 12.5, height: 1.5, color: palette.ink),
            ),
          ],
          if (expected.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              '期望：$expected',
              style: TextStyle(fontSize: 12.5, height: 1.5, color: palette.ink),
            ),
          ],
        ],
      ),
    );
  }

  Widget _noticeRow(bool error, HomePalette palette) {
    final color = aiFeedbackToneColor(
      palette,
      error ? AiStatusTone.error : AiStatusTone.ok,
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          error ? LucideIcons.circle_alert : LucideIcons.circle_check,
          size: 16,
          color: color,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            _notice!,
            style: TextStyle(fontSize: 12.5, height: 1.5, color: color),
          ),
        ),
      ],
    );
  }

  Widget _actions(HomePalette palette) {
    final destructive = palette.eink ? palette.ink : const Color(0xFF9C3D33);
    final status = _case.status;
    final buttons = <Widget>[];
    if (status == AiFeedbackStatus.deleted) {
      buttons.add(
        FilledButton(
          onPressed: _busy ? null : _restore,
          child: const Text('恢复'),
        ),
      );
      buttons.add(
        OutlinedButton(
          onPressed: _busy ? null : _deletePermanent,
          style: OutlinedButton.styleFrom(
            foregroundColor: destructive,
            side: BorderSide(color: palette.line, width: 0.8),
          ),
          child: const Text('永久删除'),
        ),
      );
    } else {
      if (status == AiFeedbackStatus.active) {
        buttons.add(
          OutlinedButton(
            onPressed: _busy ? null : _archive,
            style: OutlinedButton.styleFrom(
              foregroundColor: palette.ink,
              side: BorderSide(color: palette.line, width: 0.8),
            ),
            child: const Text('归档'),
          ),
        );
      } else if (status == AiFeedbackStatus.archived) {
        buttons.add(
          FilledButton(
            onPressed: _busy ? null : _restore,
            child: const Text('恢复'),
          ),
        );
      }
      buttons.add(
        OutlinedButton(
          onPressed: _busy ? null : _deleteSoft,
          style: OutlinedButton.styleFrom(
            foregroundColor: destructive,
            side: BorderSide(color: palette.line, width: 0.8),
          ),
          child: const Text('删除'),
        ),
      );
      buttons.add(
        OutlinedButton(
          onPressed: _busy ? null : _deletePermanent,
          style: OutlinedButton.styleFrom(
            foregroundColor: destructive,
            side: BorderSide(color: palette.line, width: 0.8),
          ),
          child: const Text('永久删除'),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_busy)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: LinearProgressIndicator(
              minHeight: 2,
              color: palette.accentText,
              backgroundColor: palette.line,
            ),
          ),
        Wrap(spacing: 8, runSpacing: 8, children: buttons),
        if (status == AiFeedbackStatus.superseded) ...[
          const SizedBox(height: 8),
          Text(
            '这条反馈已经被新的认可改法替代，只保留为历史证据。',
            style: TextStyle(fontSize: 12.5, height: 1.5, color: palette.muted),
          ),
        ],
      ],
    );
  }

  Widget _technicalDetails(HomePalette palette) {
    final protection = _latestProtection;
    final observation = _case.originalObservation;
    final runId = observation?['sourceRunId'];
    final editIndex = observation?['sourceEditIndex'];
    final entries = <(String, String)>[
      ('反馈 ID', _case.feedbackId),
      ('章节 ID', _case.chapterId),
      (
        '原文区间',
        '${_case.anchor.sourceStart}–${_case.anchor.sourceEnd}，'
            '第 ${_case.anchor.paragraphIndex + 1} 段',
      ),
      ('正文哈希', _case.canonicalHash),
      if (protection != null) ('保护 ID', protection.protectionId),
      if (protection?.approvedEdit?.sourceEditIndex != null)
        ('保护来源 edit 序号', '${protection!.approvedEdit!.sourceEditIndex}'),
      if (runId is String) ('来源运行', runId),
      if (editIndex is int) ('来源 edit 序号', '$editIndex'),
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: SettingsGroupCard(
        children: [
          for (final (label, value) in entries)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.3,
                      color: palette.muted,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    value,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.4,
                      color: palette.ink,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// 一行「标题 + 右侧值」，值最多三行并省略，避免长说明把行撑爆。
class _FieldRow extends StatelessWidget {
  const _FieldRow({
    required this.title,
    this.subtitle,
    required this.value,
    this.onTap,
  });

  final String title;
  final String? subtitle;
  final String value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final content = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: SettingsRow.minHeight),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: Row(
          children: [
            Expanded(
              flex: 4,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 15,
                      height: 1.3,
                      fontWeight: FontWeight.w600,
                      color: palette.ink,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      subtitle!,
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.4,
                        color: palette.muted,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            Flexible(
              flex: 5,
              child: Text(
                value,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: TextStyle(fontSize: 13, height: 1.4, color: palette.ink),
              ),
            ),
            if (onTap != null) ...[
              const SizedBox(width: 4),
              Icon(LucideIcons.chevron_right, size: 16, color: palette.muted),
            ],
          ],
        ),
      ),
    );
    if (onTap == null) return content;
    return HomePressable(
      onTap: onTap!,
      borderRadius: BorderRadius.circular(SettingsGroupCard.radius),
      semanticLabel: subtitle == null ? title : '$title，$subtitle',
      child: content,
    );
  }
}
