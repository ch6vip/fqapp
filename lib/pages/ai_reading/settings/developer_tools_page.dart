import 'dart:async';

import 'package:flutter/material.dart';

import '../../../services/ai_reading/ai_chapter_snapshot.dart';
import '../../../services/ai_reading/ai_controller.dart';
import '../../../services/ai_reading/ai_coordinator.dart';
import '../../../services/ai_reading/ai_models.dart';
import '../../../services/ai_reading/ai_prompt.dart';
import '../../../services/ai_reading/ai_settings.dart';
import '../../../widgets/wenku/wenku_ui.dart';
import '../../../widgets/ai_reading/ai_ui.dart';
import '../../../widgets/home/home_design.dart';
import 'ai_sandbox_style.dart';
import 'ai_prompt_editor_page.dart';
import 'ai_sandbox_json_page.dart';
import 'ai_sandbox_request_page.dart';
import 'ai_sandbox_widgets.dart';
import 'ai_settings_widgets.dart';

class DeveloperToolsPage extends StatefulWidget {
  const DeveloperToolsPage({super.key, this.coordinator});
  final AiCoordinator? coordinator;
  @override
  State<DeveloperToolsPage> createState() => _DeveloperToolsPageState();
}

class _DeveloperToolsPageState extends State<DeveloperToolsPage> {
  static const _bookId = '__developer_ai_sandbox__';
  final _settings = AiSettingsStore.instance;
  final _input = TextEditingController(text: aiSandboxSample);
  final _json = AiSandboxJsonState();
  late bool _restore;
  String? _customBehavior;
  bool _running = false;
  Completer<void>? _cancel;
  AiStreamProgress? _progress;
  String _stage = '连接中';
  AiSandboxRequest? _request;
  AiSandboxResult? _result;

  String get _globalBehavior => aiResolvePrompt(
    bookPrompt: null,
    globalPrompt: _settings.global.behaviorPrompt,
  ).text;

  @override
  void initState() {
    super.initState();
    _restore = _settings.global.restoreCensoredWords;
    _input.addListener(_inputChanged);
  }

  void _inputChanged() {
    if (!_running && mounted) setState(() => _request = null);
  }

  AiSandboxRequest _capture() {
    final snapshot = AiChapterSnapshotBuilder.fromContent(
      aiSandboxContent(_input.text),
      '',
    );
    final effective = _settings.resolve(_bookId);
    return AiSandboxRequest(
      source: snapshot.requestText,
      behavior: _customBehavior ?? _globalBehavior,
      behaviorSource: _customBehavior == null ? '全局提示词' : '本次自定义提示词',
      restore: _restore,
      settings: effective,
      provider: _settings.provider(effective.providerId),
    );
  }

  Future<void> _editBehavior() async {
    final global = _globalBehavior;
    final text = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => AiPromptEditorPage(
          title: '测试行为提示词',
          initial: _customBehavior ?? global,
          actionLabel: '使用',
          restoreText: global,
        ),
      ),
    );
    if (!mounted || text == null) return;
    setState(() {
      _customBehavior = text == global ? null : text;
      _request = null;
    });
  }

  void _openJson({bool useResponse = false}) {
    if (useResponse) {
      _json.original.text = _result!.source;
      _json.response.text = _result!.raw!;
      _json.result = null;
    }
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => AiSandboxJsonPage(state: _json, sample: _input.text),
      ),
    );
  }

  bool get _previousResult {
    final request = _result?.request;
    if (request == null) return false;
    try {
      return !request.hasSameInputs(_capture());
    } on AiSnapshotException {
      return true;
    }
  }

  void _viewRequest({AiSandboxRequest? resultRequest}) {
    try {
      final request = resultRequest ?? (_running ? _request! : _capture());
      Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => AiSandboxRequestPage(request: request),
        ),
      );
    } on AiSnapshotException catch (error) {
      aiShowSnack(context, error.message);
    }
  }

  void _stop() {
    if (_cancel?.isCompleted == false) _cancel!.complete();
    if (mounted && _running) setState(() => _stage = '停止中');
  }

  Future<void> _run() async {
    if (_running) return;
    if (_input.text.trim().isEmpty) {
      aiShowSnack(context, '请输入测试正文');
      return;
    }
    final AiSandboxRequest request;
    try {
      request = _capture();
    } on AiSnapshotException catch (error) {
      aiShowSnack(context, error.message);
      return;
    }
    final cancel = Completer<void>();
    final watch = Stopwatch()..start();
    _cancel = cancel;
    setState(() {
      _running = true;
      _result = null;
      _request = request;
      _progress = null;
      _stage = '连接中';
    });
    try {
      await AiReadingController.instance.init();
      if (!mounted || cancel.isCompleted) return;
      Future<AiTaskResult> attempt({bool confirmed = false}) =>
          (widget.coordinator ?? AiCoordinator.instance).runFormal(
            bookId: _bookId,
            chapterId: 'sample',
            chapterTitle: '',
            content: aiSandboxContent(request.source),
            kind: AiRunKind.trial,
            behaviorPromptOverride: request.behavior,
            restoreCensoredWords: request.restore,
            settingsSnapshot: request.settings,
            providerSnapshot: request.provider,
            allowRetries: false,
            confirmedOverBudget: confirmed,
            cancelTrigger: cancel.future,
            onState: (state) {
              if (mounted &&
                  !cancel.isCompleted &&
                  state == AiRunState.validating) {
                setState(() => _stage = '校验中');
              }
            },
            onProgress: (progress) {
              if (mounted && !cancel.isCompleted) {
                setState(() {
                  _progress = progress;
                  _stage = progress.contentChars > 0
                      ? '生成中'
                      : progress.reasoningChars > 0
                      ? '思考中'
                      : '连接中';
                });
              }
            },
          );
      var result = await attempt();
      if (!mounted || cancel.isCompleted) {
        if (mounted) _setResult(request, result, watch.elapsed, stopped: true);
        return;
      }
      if (result.needsBudgetConfirmation) {
        watch.stop();
        final confirmed = await showAiBudgetDialog(
          context,
          result.budgetMessage ?? '本次请求将超出预算',
        );
        if (!mounted || cancel.isCompleted) return;
        if (confirmed) {
          watch
            ..reset()
            ..start();
          result = await attempt(confirmed: true);
        }
      }
      if (mounted) {
        _setResult(request, result, watch.elapsed, stopped: cancel.isCompleted);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _result = AiSandboxResult(
            title: cancel.isCompleted ? '测试已停止' : '测试失败',
            source: request.source,
            request: request,
            elapsed: watch.elapsed,
            message: '测试请求未完成：$error',
          );
        });
      }
    } finally {
      watch.stop();
      if (identical(_cancel, cancel)) _cancel = null;
      if (mounted) {
        setState(() {
          _running = false;
          _request = null;
          _result ??= AiSandboxResult(
            title: '测试已停止',
            source: request.source,
            request: request,
            elapsed: watch.elapsed,
            requests: 0,
          );
        });
      }
    }
  }

  void _setResult(
    AiSandboxRequest request,
    AiTaskResult result,
    Duration elapsed, {
    required bool stopped,
  }) {
    setState(() {
      _result = AiSandboxResult(
        title: stopped || result.errorCodes.contains('REQUEST_ABORTED')
            ? '测试已停止'
            : result.ok
            ? '测试完成'
            : '测试失败',
        request: request,
        source: result.snapshot.requestText,
        raw: result.rawResponse,
        validation: result.validation,
        elapsed: elapsed,
        requests: result.requestCount,
        usage: result.usage,
        message: result.ok
            ? null
            : [
                if (result.error != null) result.error!,
                ...result.errorCodes,
              ].join(' · '),
      );
    });
  }

  @override
  void dispose() {
    if (_cancel?.isCompleted == false) _cancel!.complete();
    _input.dispose();
    _json.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope<void>(
    onPopInvokedWithResult: (didPop, _) {
      if (didPop) _stop();
    },
    child: AnimatedBuilder(
      animation: _settings,
      builder: (context, _) {
        final provider = _running
            ? _request?.provider
            : _settings.provider(_settings.global.providerId);
        final model = _running
            ? _request?.settings.modelId
            : _settings.global.modelId;
        final progress = _progress;
        return AppFeaturePage(
          title: 'AI 测试台',
          code: 'AI / SANDBOX',
          actions: [
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_horiz),
              style: IconButton.styleFrom(
                minimumSize: const Size(48, 48),
                visualDensity: VisualDensity.standard,
              ),
              tooltip: '更多工具',
              onSelected: (_) => _openJson(),
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'json', child: Text('JSON 校验')),
              ],
            ),
          ],
          child: AiSandboxLayout(
            padding: featurePadding(context),
            header: AiSandboxProviderSummary(
              provider: provider?.label ?? '未选择提供商',
              model: model ?? '未选择模型',
              onViewRequest: _viewRequest,
            ),
            empty: _result == null,
            input: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AiSandboxField(
                  label: '测试正文',
                  controller: _input,
                  enabled: !_running,
                  action: TextButton(
                    onPressed: _running
                        ? null
                        : () => setState(() {
                            _input.text = aiSandboxSample;
                            _request = null;
                          }),
                    child: const Text('填入示例'),
                  ),
                ),
                const SizedBox(height: 8),
                InkWell(
                  onTap: _running ? null : _editBehavior,
                  child: Container(
                    constraints: const BoxConstraints(minHeight: 56),
                    decoration: BoxDecoration(
                      border: Border(
                        bottom: BorderSide(color: AiSandboxStyle(context).line),
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: LayoutBuilder(
                        builder: (context, constraints) => Row(
                          children: [
                            Expanded(
                              child: Text(
                                '行为提示词',
                                style: TextStyle(
                                  fontSize: 14,
                                  color: HomePalette.of(context).ink,
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            ConstrainedBox(
                              constraints: BoxConstraints(
                                maxWidth: (constraints.maxWidth - 44) / 2,
                              ),
                              child: Text(
                                _customBehavior == null ? '全局' : '本次自定义',
                                textAlign: TextAlign.end,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: HomePalette.of(context).muted,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Icon(
                              Icons.chevron_right,
                              size: 16,
                              color: HomePalette.of(context).muted,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                AiSandboxRestoreOption(
                  value: _restore,
                  onChanged: _running
                      ? null
                      : (value) => setState(() {
                          _restore = value;
                          _request = null;
                        }),
                ),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final start = FilledButton(
                      style: AiSandboxStyle(context).runButton,
                      onPressed: _running ? null : _run,
                      child: Text(
                        _running
                            ? '$_stage${progress == null ? '…' : ' ${progress.exact ? '' : '约 '}${progress.estimatedTokens} tokens'}'
                            : '开始测试',
                      ),
                    );
                    final stop = OutlinedButton(
                      style: AiSandboxStyle(context).stopButton,
                      onPressed: _stop,
                      child: const Text('停止'),
                    );
                    if (_running &&
                        constraints.maxWidth <
                            260 *
                                MediaQuery.textScalerOf(context).scale(14) /
                                14) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [start, const SizedBox(height: 8), stop],
                      );
                    }
                    return Row(
                      children: [
                        Expanded(child: start),
                        if (_running) ...[const SizedBox(width: 12), stop],
                      ],
                    );
                  },
                ),
              ],
            ),
            result: AiSandboxResultView(
              result: _result,
              previous: _previousResult,
              onViewRequest: () =>
                  _viewRequest(resultRequest: _result!.request),
              onValidate: () => _openJson(useResponse: true),
            ),
          ),
        );
      },
    ),
  );
}
