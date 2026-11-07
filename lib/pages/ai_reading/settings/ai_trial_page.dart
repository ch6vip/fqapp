import 'package:flutter/material.dart';

import '../../../models/media_item.dart';
import '../../../services/ai_reading/ai_chapter_snapshot.dart';
import '../../../services/ai_reading/ai_controller.dart';
import '../../../services/ai_reading/ai_feedback.dart';
import '../../../services/ai_reading/ai_trials.dart';
import '../../../services/chapter_cache_store.dart';
import '../../../services/chapter_text_formatter.dart';
import '../../../services/ai_reading/ai_models.dart';
import '../../../services/ai_reading/ai_settings.dart';
import '../../../services/ai_reading/ai_store.dart';
import '../../../widgets/ai_reading/ai_ui.dart';
import '../../../widgets/home/home_design.dart';
import '../../../widgets/settings/settings_widgets.dart';
import 'ai_settings_widgets.dart';

/// Read-only trial history for one book. Running a new trial needs a feedback
/// case selection and the coordinator, so the action stays disabled here.
class AiTrialPage extends StatefulWidget {
  const AiTrialPage({super.key, required this.bookId, required this.title});

  final String bookId;
  final String title;

  @override
  State<AiTrialPage> createState() => _AiTrialPageState();
}

class _AiTrialPageState extends State<AiTrialPage> {
  List<AiTrialRecord> _trials = const [];
  Map<String, List<AiTrialResultRecord>> _results = const {};
  Map<String, int> _requestCounts = const {};
  Map<String, int> _requestCosts = const {};
  Set<String> _unknownCostRuns = const {};
  bool _loading = true;
  bool _running = false;
  String? _error;
  List<AiFeedbackCase> _trialCases = const [];
  List<AiTrialChapter> _trialChapters = const [];
  List<AiPromptCandidate> _candidates = const [];
  String? _selectedCandidateId;

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
      final storedTrials = (await AiStore.instance.trials())
          .where((trial) => trial.bookId == widget.bookId)
          .toList(growable: false);
      final trials = <AiTrialRecord>[];
      for (final trial in storedTrials) {
        if (trial.state != 'running') {
          trials.add(trial);
          continue;
        }
        // A trial runs inside this page. Seeing a running record on load means
        // the process died before it could finish.
        final interrupted = AiTrialRecord(
          trialId: trial.trialId,
          bookId: trial.bookId,
          candidateHash: trial.candidateHash,
          configSnapshotHash: trial.configSnapshotHash,
          feedbackSnapshotHash: trial.feedbackSnapshotHash,
          feedbackCaseRevisions: trial.feedbackCaseRevisions,
          chapterHashes: trial.chapterHashes,
          startedAt: trial.startedAt,
          state: 'interrupted',
        );
        await AiStore.instance.putTrial(interrupted);
        trials.add(interrupted);
      }
      trials.sort((a, b) => b.startedAt.compareTo(a.startedAt));
      final results = await AiStore.instance.trialResults();
      final requests = await AiStore.instance.requests();
      final byTrial = <String, List<AiTrialResultRecord>>{};
      for (final result in results) {
        if (!trials.any((trial) => trial.trialId == result.trialId)) continue;
        byTrial.putIfAbsent(result.trialId, () => []).add(result);
      }
      final counts = <String, int>{};
      final costs = <String, int>{};
      final unknown = <String>{};
      for (final request in requests) {
        counts.update(request.runId, (value) => value + 1, ifAbsent: () => 1);
        costs.update(
          request.runId,
          (value) => value + (request.costMicros ?? 0),
          ifAbsent: () => request.costMicros ?? 0,
        );
        if (request.usage.status == AiUsageStatus.unknown ||
            request.costMicros == null) {
          unknown.add(request.runId);
        }
      }
      if (!mounted) return;
      setState(() {
        _trials = trials;
        _results = byTrial;
        _requestCounts = counts;
        _requestCosts = costs;
        _unknownCostRuns = unknown;
        _loading = false;
      });
      await _loadTrialInputs();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$error';
      });
    }
  }

  Future<void> _loadTrialInputs() async {
    try {
      final candidates =
          (await AiStore.instance.candidates())
              .where((candidate) => candidate.bookId == widget.bookId)
              .toList(growable: false)
            ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      final aggregates = await AiFeedbackService.instance.aggregatesForBook(
        widget.bookId,
      );
      final cases = [
        for (final aggregate in aggregates)
          for (final item in aggregate.cases)
            if (item.isActive) item,
      ];
      final cache = ChapterCacheStore.instance;
      final book =
          await cache.cachedBook(widget.bookId) ??
          await cache.savedCatalogue(widget.bookId);
      final chapters = <AiTrialChapter>[];
      final seen = <String>{};
      if (book != null) {
        for (final feedback in cases) {
          if (!seen.add(feedback.chapterId)) continue;
          Chapter? chapter;
          for (final item in book.chapters) {
            if (item.itemId == feedback.chapterId) {
              chapter = item;
              break;
            }
          }
          if (chapter == null) continue;
          final text = await cache.read(
            bookId: widget.bookId,
            chapterId: chapter.itemId,
          );
          if (text == null) continue;
          final content = ChapterContent.fromCacheText(text);
          final snapshot = AiChapterSnapshotBuilder.fromContent(
            content,
            chapter.title,
          );
          if (snapshot.canonicalHash != feedback.canonicalHash) continue;
          chapters.add(
            AiTrialChapter(
              chapterId: chapter.itemId,
              title: chapter.title,
              content: content,
            ),
          );
        }
      }
      if (!mounted) return;
      setState(() {
        _trialCases = cases;
        _trialChapters = chapters;
        _candidates = candidates;
        if (_selectedCandidateId != null &&
            !candidates.any((c) => c.candidateId == _selectedCandidateId)) {
          _selectedCandidateId = null;
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _trialCases = const [];
        _trialChapters = const [];
      });
    }
  }

  Future<void> _runTrial() async {
    if (_running || _trialCases.isEmpty || _trialChapters.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('运行整章试验？'),
        content: Text(
          '将用${_selectedCandidateId == null ? '当前本书提示词' : '选中的候选提示词'}，'
          '对 ${_trialChapters.length} 个章节发送完整原文请求，'
          '并按 ${_trialCases.length} 条反馈评分。可能产生 API 费用，结果不会写入正式缓存。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('开始试验'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _running = true);
    try {
      final selected = _selectedCandidateId == null
          ? null
          : _candidates
                .where((c) => c.candidateId == _selectedCandidateId)
                .firstOrNull;
      final prompt =
          selected?.body ??
          AiSettingsStore.instance.resolvedPrompt(widget.bookId).text;
      try {
        await AiTrialService.instance.run(
          bookId: widget.bookId,
          candidatePrompt: prompt,
          chapters: _trialChapters,
          feedbackCases: _trialCases,
        );
      } on AiTrialNeedsBudget catch (error) {
        if (!mounted) return;
        final go = await showAiBudgetDialog(context, error.message);
        if (!go || !mounted) return;
        await AiTrialService.instance.run(
          bookId: widget.bookId,
          candidatePrompt: prompt,
          chapters: _trialChapters,
          feedbackCases: _trialCases,
          confirmedOverBudget: true,
        );
      }
      await _load();
      if (mounted) aiShowSnack(context, '试验完成');
    } catch (error) {
      if (mounted) aiShowSnack(context, '试验失败：$error');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsScaffold(
      title: '试验结果',
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
              '试验记录读取失败',
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
    final currentPrompt = AiSettingsStore.instance.resolvedPrompt(
      widget.bookId,
    );
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        SettingsGroupCard(
          children: [
            SettingsRow(
              title: '试验提示词',
              value: _selectedCandidateId == null ? '当前生效' : '候选',
              onTap: _candidates.isEmpty
                  ? null
                  : () async {
                      final choice = await showAiChoiceDialog(
                        context,
                        title: '选择试验提示词',
                        options: [
                          (
                            key: '__current__',
                            label: '当前生效（v${currentPrompt.promptId}）',
                            selected: _selectedCandidateId == null,
                          ),
                          for (final candidate in _candidates)
                            (
                              key: candidate.candidateId,
                              label:
                                  '候选 ${aiFormatDateTime(candidate.createdAt)}',
                              selected:
                                  _selectedCandidateId == candidate.candidateId,
                            ),
                        ],
                      );
                      if (choice == null || !mounted) return;
                      setState(() {
                        _selectedCandidateId = choice == '__current__'
                            ? null
                            : choice;
                      });
                    },
            ),
            if (_selectedCandidateId != null)
              SettingsRow(
                title: '候选内容',
                subtitle: _candidates
                    .firstWhere(
                      (candidate) =>
                          candidate.candidateId == _selectedCandidateId,
                    )
                    .body,
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (_trials.isEmpty)
          AiInfoCard(
            title: '还没有试验记录',
            body: '运行一次试验后会显示在这里。',
            icon: Icons.history_toggle_off,
          )
        else
          for (final trial in _trials) ...[
            _trialCard(context, trial),
            const SizedBox(height: 16),
          ],
        FilledButton(
          onPressed: _running || _trialCases.isEmpty || _trialChapters.isEmpty
              ? null
              : _runTrial,
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(46)),
          child: _running
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(
                  _selectedCandidateId == null ? '用当前提示词运行试验' : '用候选提示词运行试验',
                ),
        ),
      ],
    );
  }

  Future<void> _rescore(AiTrialRecord trial) async {
    if (_running) return;
    if (_trialCases.isEmpty) {
      aiShowSnack(context, '没有可用于评分的反馈');
      return;
    }
    setState(() => _running = true);
    try {
      final result = await AiTrialService.instance.rescore(
        bookId: widget.bookId,
        trialId: trial.trialId,
        feedbackCases: _trialCases,
      );
      await _load();
      if (mounted) {
        aiShowSnack(
          context,
          '已用本机原始输出重新评分 ${result.rescored} 章'
          '${result.skipped > 0 ? '，${result.skipped} 章缺少原始输出或正文已变' : ''}',
        );
      }
    } catch (error) {
      if (mounted) aiShowSnack(context, '重新评分失败：$error');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Widget _trialCard(BuildContext context, AiTrialRecord trial) {
    final palette = HomePalette.of(context);
    final results = _results[trial.trialId] ?? const <AiTrialResultRecord>[];
    final verdicts = <AiTrialVerdict, int>{};
    for (final result in results) {
      for (final feedback in result.perFeedback) {
        verdicts.update(
          feedback.verdict,
          (value) => value + 1,
          ifAbsent: () => 1,
        );
      }
    }
    var requestCount = 0;
    var costMicros = 0;
    var costUnknown = false;
    for (final result in results) {
      requestCount += _requestCounts[result.runId] ?? 0;
      costMicros += _requestCosts[result.runId] ?? 0;
      if (_unknownCostRuns.contains(result.runId)) costUnknown = true;
    }
    final currency = AiSettingsStore.instance.global.costCurrency;
    final costText = requestCount == 0 || (costUnknown && costMicros == 0)
        ? '未知'
        : costUnknown
        ? '${aiFormatCostMicros(costMicros, currency)}，部分未知'
        : aiFormatCostMicros(costMicros, currency);
    final verdictText = verdicts.isEmpty
        ? '没有逐条判定'
        : verdicts.entries
              .map((entry) => '${entry.key.label} ${entry.value}')
              .join('，');
    return SettingsGroupCard(
      showDividers: false,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  aiFormatDateTime(trial.startedAt),
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: palette.ink,
                  ),
                ),
              ),
              AiStatusPill(
                label: _stateLabel(trial.state),
                tone: trial.state == 'failed' || trial.state == 'interrupted'
                    ? AiStatusTone.error
                    : trial.state == 'running'
                    ? AiStatusTone.warn
                    : AiStatusTone.neutral,
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            '章节 ${trial.chapterHashes.length} 条，已记录 ${results.length} 条，'
            '反馈快照 ${trial.feedbackCaseRevisions.length} 条',
            style: TextStyle(fontSize: 12.5, height: 1.4, color: palette.muted),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Text(
            '请求 $requestCount 次，费用 $costText'
            '${verdictText.isEmpty ? '' : '。$verdictText'}',
            style: TextStyle(fontSize: 12.5, height: 1.45, color: palette.ink),
          ),
        ),
        if (results.isNotEmpty)
          Divider(height: 1, color: palette.line)
        else
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              '这轮试验没有结果记录，可能是请求失败或摘要已被清理。',
              style: TextStyle(fontSize: 12, height: 1.4, color: palette.muted),
            ),
          ),
        for (final result in results)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${_chapterLabel(result.chapterId)}，'
                  '${_validationLabel(result.validationStatus)}',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: palette.ink,
                  ),
                ),
                const SizedBox(height: 4),
                if (result.perFeedback.isEmpty)
                  Text(
                    '没有逐条判定。',
                    style: TextStyle(fontSize: 12, color: palette.muted),
                  )
                else
                  for (final feedback in result.perFeedback)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(
                              _feedbackLabel(feedback.feedbackId),
                              style: TextStyle(
                                fontSize: 12.5,
                                height: 1.4,
                                color: palette.muted,
                              ),
                            ),
                          ),
                          Text(
                            feedback.verdict.label,
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: palette.ink,
                            ),
                          ),
                        ],
                      ),
                    ),
              ],
            ),
          ),
        if (results.any((result) => result.rawValidatedEdits != null))
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: OutlinedButton(
              onPressed: _running ? null : () => _rescore(trial),
              child: const Text('用当前反馈离线重新评分'),
            ),
          )
        else
          const SizedBox(height: 10),
      ],
    );
  }

  String _chapterLabel(String chapterId) {
    for (final chapter in _trialChapters) {
      if (chapter.chapterId == chapterId) return chapter.title;
    }
    return '章节';
  }

  String _feedbackLabel(String feedbackId) {
    final index = _trialCases.indexWhere(
      (feedback) => feedback.feedbackId == feedbackId,
    );
    if (index < 0) return '反馈';
    return '反馈 ${index + 1} · ${_trialCases[index].kind.label}';
  }

  static String _validationLabel(String status) => switch (status) {
    'valid' => '已逐条判定',
    'failed' => '未通过校验',
    _ => status,
  };

  static String _stateLabel(String state) => switch (state) {
    'running' => '进行中',
    'completed' || 'success' || 'done' => '已完成',
    'failed' => '失败',
    'interrupted' => '已中断',
    'cancelled' => '已取消',
    _ => state,
  };
}
