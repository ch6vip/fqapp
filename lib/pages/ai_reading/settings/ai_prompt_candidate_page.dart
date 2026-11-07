import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../services/ai_reading/ai_controller.dart';
import '../../../services/ai_reading/ai_feedback.dart';
import '../../../services/ai_reading/ai_models.dart';
import '../../../services/ai_reading/ai_prompt_service.dart';
import '../../../services/ai_reading/ai_settings.dart';
import '../../../services/ai_reading/ai_store.dart';
import '../../../widgets/ai_reading/ai_ui.dart';
import '../../../widgets/home/home_design.dart';
import '../../../widgets/settings/settings_widgets.dart';
import 'ai_settings_widgets.dart';

/// Prompt candidates for one book. This page never calls a model; it lists
/// stored drafts, shows a line diff against the current prompt, and lets the
/// user adopt one as the book-level override.
class AiPromptCandidatePage extends StatefulWidget {
  const AiPromptCandidatePage({
    super.key,
    required this.bookId,
    required this.title,
  });

  final String bookId;
  final String title;

  @override
  State<AiPromptCandidatePage> createState() => _AiPromptCandidatePageState();
}

class _AiPromptCandidatePageState extends State<AiPromptCandidatePage> {
  final _settings = AiSettingsStore.instance;
  final _store = AiStore.instance;

  List<AiPromptCandidate> _candidates = const [];
  List<AiPromptRecord> _history = const [];
  String _currentPrompt = '';
  bool _loading = true;
  bool _busy = false;
  bool _generating = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await AiReadingController.instance.init();
      final resolved = _settings.resolvedPrompt(widget.bookId);
      final candidates =
          (await _store.candidates())
              .where((item) => item.bookId == widget.bookId)
              .toList(growable: false)
            ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      final history = await AiPromptService.instance.history(widget.bookId);
      if (!mounted) return;
      setState(() {
        _currentPrompt = resolved.text;
        _candidates = candidates;
        _history = history;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$error';
      });
    }
  }

  Future<void> _createDraft() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final resolved = _settings.resolvedPrompt(widget.bookId);
      final candidate = AiPromptCandidate(
        candidateId: 'cand_${DateTime.now().millisecondsSinceEpoch}',
        bookId: widget.bookId,
        basePromptId: resolved.promptId,
        body: resolved.text,
        draftState: 'draft',
        feedbackCaseRevisions: const {},
        createdAt: DateTime.now(),
      );
      await _store.putCandidate(candidate);
      if (!mounted) return;
      aiShowSnack(context, '已用当前提示词创建草稿');
      await _load();
    } catch (error) {
      if (!mounted) return;
      aiShowSnack(context, '创建草稿失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _generateFromFeedback() async {
    if (_busy || _generating) return;
    final controller = AiReadingController.instance;
    if (!controller.settings.device.cloudConsent) {
      aiShowSnack(context, '请先在全局设置里同意云端正文传输');
      return;
    }
    final effective = controller.settings.resolve(widget.bookId);
    if (!effective.enabled) {
      aiShowSnack(context, '请先开启 AI 阅读优化');
      return;
    }
    final aggregates = await AiFeedbackService.instance.aggregatesForBook(
      widget.bookId,
    );
    if (!mounted) return;
    final cases = [
      for (final aggregate in aggregates)
        for (final item in aggregate.cases)
          if (item.isActive) item,
    ];
    if (cases.isEmpty) {
      aiShowSnack(context, '还没有生效中的反馈用例');
      return;
    }
    setState(() => _generating = true);
    try {
      await AiPromptService.instance.createFromFeedback(
        bookId: widget.bookId,
        feedback: cases,
      );
      if (!mounted) return;
      aiShowSnack(context, '候选已生成，请检查 diff 后再采纳');
      await _load();
    } catch (error) {
      if (mounted) aiShowSnack(context, '生成候选失败：$error');
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  Future<void> _preview() async {
    final system = await AiPromptService.instance.previewSystemPrompt(
      widget.bookId,
    );
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('系统提示词预览'),
        content: SizedBox(
          width: double.maxFinite,
          height: 420,
          child: SingleChildScrollView(
            child: SelectableText(
              system,
              style: const TextStyle(fontSize: 12.5, height: 1.5),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _undoLastAdopt() async {
    if (_busy) return;
    final confirmed = await showSettingsConfirmDialog(
      context: context,
      title: '撤销最近一次采纳？',
      message: '会恢复上一版提示词；没有上一版时恢复继承全局。已缓存的正式结果不刷新。',
      confirmLabel: '撤销',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    setState(() => _busy = true);
    try {
      await AiPromptService.instance.undoLastAdopt(widget.bookId);
      if (!mounted) return;
      aiShowSnack(context, '已撤销最近一次采纳');
      await _load();
    } catch (error) {
      if (mounted) aiShowSnack(context, '撤销失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _adopt(AiPromptCandidate candidate) async {
    if (_busy) return;
    final confirmed = await showSettingsConfirmDialog(
      context: context,
      title: '采纳这个候选？',
      message:
          '会写入本书提示词覆写，只影响之后发起的校对；'
          '已缓存的正式结果不会刷新。',
      confirmLabel: '采纳',
    );
    if (!confirmed) return;
    setState(() => _busy = true);
    try {
      await AiPromptService.instance.adopt(candidate);
      if (!mounted) return;
      aiShowSnack(context, '已采纳，之后的校对会使用本书提示词');
      await _load();
    } catch (error) {
      if (!mounted) return;
      aiShowSnack(context, '采纳失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsScaffold(
      title: '提示词候选',
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? _errorView()
          : _content(context),
    );
  }

  Widget _errorView() {
    final palette = HomePalette.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '候选读取失败',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: palette.ink,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _error ?? '',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.4,
                color: palette.muted,
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      ),
    );
  }

  Widget _content(BuildContext context) {
    final palette = HomePalette.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        if (_candidates.isEmpty)
          AiInfoCard(
            title: '还没有候选',
            body: '用反馈生成或手动创建草稿。',
            icon: Icons.article_outlined,
          )
        else
          for (final (index, candidate) in _candidates.indexed) ...[
            _candidateCard(
              context,
              candidate,
              version: _candidates.length - index,
            ),
            const SizedBox(height: 16),
          ],
        if (_history.isNotEmpty) ...[
          const SettingsSectionHeader(title: '提示词历史'),
          const SizedBox(height: 8),
          SettingsGroupCard(
            children: [
              for (final record in _history.take(6))
                SettingsRow(
                  title: record.active
                      ? '当前版本 v${record.revision}'
                      : 'v${record.revision}',
                  subtitle:
                      '${record.source} · ${aiFormatDateTime(record.createdAt)}',
                  value: record.text.length > 40
                      ? '${record.text.substring(0, 40)}…'
                      : record.text,
                ),
              SettingsRow(
                title: '撤销最近一次采纳',
                showChevron: false,
                onTap: _busy ? null : _undoLastAdopt,
              ),
            ],
          ),
          const SizedBox(height: 16),
        ],
        OutlinedButton(
          onPressed: _busy ? null : _preview,
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(46),
          ),
          child: const Text('预览系统提示词'),
        ),
        const SizedBox(height: 8),
        FilledButton.tonal(
          onPressed: _busy || _generating ? null : _generateFromFeedback,
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(46)),
          child: _generating
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('用反馈生成候选'),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: _busy ? null : _createDraft,
          style: OutlinedButton.styleFrom(
            foregroundColor: palette.ink,
            side: BorderSide(color: palette.line),
            minimumSize: const Size.fromHeight(46),
          ),
          child: Text(_busy ? '处理中' : '用当前提示词创建草稿'),
        ),
      ],
    );
  }

  Widget _candidateCard(
    BuildContext context,
    AiPromptCandidate candidate, {
    required int version,
  }) {
    final palette = HomePalette.of(context);
    final lines = _lineDiff(_currentPrompt, candidate.body);
    final added = lines.where((line) => line.kind == _DiffKind.add).length;
    final removed = lines.where((line) => line.kind == _DiffKind.remove).length;
    final adopted = candidate.adoptedAt != null;
    return SettingsGroupCard(
      showDividers: false,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '候选 v$version',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: palette.ink,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      aiFormatDateTime(candidate.createdAt),
                      style: TextStyle(fontSize: 12, color: palette.muted),
                    ),
                  ],
                ),
              ),
              AiStatusPill(
                label: adopted ? '已采纳' : '草稿',
                tone: adopted ? AiStatusTone.ok : AiStatusTone.neutral,
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            '与当前提示词比较：新增 $added 行，删除 $removed 行',
            style: TextStyle(fontSize: 12.5, height: 1.4, color: palette.muted),
          ),
        ),
        const SizedBox(height: 8),
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          padding: const EdgeInsets.symmetric(vertical: 8),
          constraints: const BoxConstraints(maxHeight: 240),
          decoration: BoxDecoration(
            color: palette.soft,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: palette.line, width: 0.6),
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [for (final line in lines) _diffRow(palette, line)],
            ),
          ),
        ),
        if (!adopted)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
            child: FilledButton(
              onPressed: _busy ? null : () => _adopt(candidate),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(42),
              ),
              child: const Text('采纳这个候选'),
            ),
          )
        else
          const SizedBox(height: 14),
      ],
    );
  }

  Widget _diffRow(HomePalette palette, _DiffLine line) {
    final sign = switch (line.kind) {
      _DiffKind.add => '+',
      _DiffKind.remove => '−',
      _DiffKind.same => ' ',
    };
    final background = palette.eink
        ? null
        : switch (line.kind) {
            _DiffKind.add => const Color(0x10557A46),
            _DiffKind.remove => const Color(0x109C3D33),
            _DiffKind.same => null,
          };
    final textColor = line.kind == _DiffKind.remove
        ? palette.muted
        : palette.ink;
    return Container(
      color: background,
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 14,
            child: Text(
              sign,
              style: TextStyle(fontSize: 12, height: 1.5, color: palette.muted),
            ),
          ),
          Expanded(
            child: Text(
              line.text.isEmpty ? ' ' : line.text,
              style: TextStyle(
                fontSize: 12,
                height: 1.5,
                color: textColor,
                decoration: line.kind == _DiffKind.remove
                    ? TextDecoration.lineThrough
                    : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

enum _DiffKind { same, add, remove }

class _DiffLine {
  const _DiffLine(this.kind, this.text);

  final _DiffKind kind;
  final String text;
}

List<_DiffLine> _lineDiff(String oldText, String newText) {
  final before = oldText.split('\n');
  final after = newText.split('\n');
  final rows = List.generate(
    before.length + 1,
    (_) => List<int>.filled(after.length + 1, 0),
  );
  for (var i = before.length - 1; i >= 0; i--) {
    for (var j = after.length - 1; j >= 0; j--) {
      rows[i][j] = before[i] == after[j]
          ? rows[i + 1][j + 1] + 1
          : math.max(rows[i + 1][j], rows[i][j + 1]);
    }
  }
  final lines = <_DiffLine>[];
  var i = 0;
  var j = 0;
  while (i < before.length && j < after.length) {
    if (before[i] == after[j]) {
      lines.add(_DiffLine(_DiffKind.same, before[i]));
      i++;
      j++;
    } else if (rows[i + 1][j] >= rows[i][j + 1]) {
      lines.add(_DiffLine(_DiffKind.remove, before[i]));
      i++;
    } else {
      lines.add(_DiffLine(_DiffKind.add, after[j]));
      j++;
    }
  }
  while (i < before.length) {
    lines.add(_DiffLine(_DiffKind.remove, before[i]));
    i++;
  }
  while (j < after.length) {
    lines.add(_DiffLine(_DiffKind.add, after[j]));
    j++;
  }
  return lines;
}
