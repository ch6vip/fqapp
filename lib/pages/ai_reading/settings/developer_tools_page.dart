import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../services/ai_reading/ai_apply.dart';
import '../../../services/ai_reading/ai_chapter_snapshot.dart';
import '../../../services/ai_reading/ai_controller.dart';
import '../../../services/ai_reading/ai_coordinator.dart';
import '../../../services/ai_reading/ai_models.dart';
import '../../../services/ai_reading/ai_prompt.dart';
import '../../../services/ai_reading/ai_protocol.dart';
import '../../../services/ai_reading/ai_settings.dart';
import '../../../services/app_style_tokens.dart';
import '../../../services/chapter_text_formatter.dart';
import '../../../services/webdav_sync_service.dart';
import '../../../widgets/settings/settings_widgets.dart';
import '../../../widgets/wenku/wenku_ui.dart';

class DeveloperToolsPage extends StatefulWidget {
  const DeveloperToolsPage({super.key});

  @override
  State<DeveloperToolsPage> createState() => _DeveloperToolsPageState();
}

class _DeveloperToolsPageState extends State<DeveloperToolsPage> {
  static const _bookId = '__developer_ai_sandbox__';
  final _input = TextEditingController(
    text:
        '“wcnm！”他气得拍了一下桌子。\n“我踏马真是服了。”他叹了口气。\n她说：“啊，原来如此。”\n他拿出手机，打开*****给朋友发消息。\n“你这个*****！”他指着背叛自己的朋友骂道。',
  );
  final _json = TextEditingController(text: '{"edits":[]}');
  bool _restore = true;
  bool _running = false;
  String? _result;
  String? _output;
  List<AiEditSpan> _spans = const [];
  Completer<void>? _cancel;
  final _settings = AiSettingsStore.instance;

  String get _prompt => aiResolvePrompt(
    bookPrompt: null,
    globalPrompt: _settings.global.behaviorPrompt,
    restoreCensoredWords: _restore,
  ).text;

  String get _protocol =>
      _settings.provider(_settings.global.providerId)?.outputMode ==
          AiOutputMode.jsonSchema
      ? jsonEncode(aiJsonSchemaProjection())
      : kAiJsonObjectProtocol;

  ChapterContent get _content => ChapterContent(
    blocks: [
      for (final line in _input.text.split(RegExp(r'\r?\n')))
        if (line.trim().isNotEmpty) ChapterParagraph(line),
    ],
  );

  void _showValidation(AiValidationResult validation, ChapterContent content) {
    if (validation.valid) {
      final snapshot = AiChapterSnapshotBuilder.fromContent(content, '');
      _output = AiApply.apply(
        snapshot: snapshot,
        source: content,
        spans: validation.spans,
      ).finalText;
      _spans = validation.spans;
    } else {
      _output = null;
      _spans = const [];
    }
  }

  void _validate() {
    try {
      final content = _content;
      final snapshot = AiChapterSnapshotBuilder.fromContent(content, '');
      final validation = const AiValidator().validateContent(
        _json.text,
        snapshot,
      );
      setState(() {
        _showValidation(validation, content);
        _result = validation.valid
            ? '离线校验通过 · ${validation.spans.length} 处修改'
            : '校验失败：${validation.errors.map((e) => e.code).join('、')}';
      });
    } catch (_) {
      setState(() => _result = '无法建立正文快照，请检查输入内容');
    }
  }

  Future<void> _run() async {
    if (_running || !_settings.device.developerMode) return;
    if (_input.text.trim().isEmpty) {
      setState(() => _result = '请输入测试正文');
      return;
    }
    final content = _content;
    final prompt = _prompt;
    final watch = Stopwatch()..start();
    final cancel = Completer<void>();
    _cancel = cancel;
    setState(() {
      _running = true;
      _result = '正在请求 AI…';
      _output = null;
      _spans = const [];
    });
    try {
      await AiReadingController.instance.init();
      if (!mounted || cancel.isCompleted || !_settings.device.developerMode) {
        return;
      }
      final result = await AiCoordinator.instance.runFormal(
        bookId: _bookId,
        chapterId: 'sample',
        chapterTitle: '',
        content: content,
        kind: AiRunKind.trial,
        behaviorPromptOverride: prompt,
        cancelTrigger: cancel.future,
      );
      if (!mounted) return;
      setState(() {
        final validation = result.validation;
        if (result.ok && validation != null) {
          _showValidation(validation, content);
          _result =
              '测试完成 · ${watch.elapsedMilliseconds} ms · '
              '${result.requestCount} 次请求 · ${_spans.length} 处修改';
        } else {
          _result = result.needsBudgetConfirmation
              ? '预算不足：${result.budgetMessage ?? '请前往 AI 设置调整预算'}'
              : '测试失败：${result.error ?? result.errorCodes.join('、')}';
        }
      });
    } catch (_) {
      if (mounted) setState(() => _result = '测试请求未完成，请检查 AI 配置、网络和设备存储');
    } finally {
      watch.stop();
      if (identical(_cancel, cancel)) _cancel = null;
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  void dispose() {
    if (_cancel?.isCompleted == false) _cancel!.complete();
    _input.dispose();
    _json.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final body = AnimatedBuilder(
      animation: _settings,
      builder: (context, _) {
        if (!_settings.device.developerMode) {
          return const Center(child: Text('请先在 AI 设置 → 高级中开启开发者模式'));
        }
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'AI 样例测试',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const Text(
              '测试不写入正式章节校对缓存，不修改书架正文。发送测试会上传下面的文本并消耗 API 额度，沿用现有授权与预算限制。',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _input,
              enabled: !_running,
              minLines: 4,
              maxLines: 10,
              decoration: const InputDecoration(
                labelText: '测试正文',
                border: OutlineInputBorder(),
              ),
            ),
            SwitchListTile(
              title: const Text('本次测试启用去屏蔽词'),
              subtitle: const Text('不改变阅读器的全局开关，可分别开关测试作对比'),
              value: _restore,
              onChanged: _running
                  ? null
                  : (value) => setState(() => _restore = value),
            ),
            ExpansionTile(
              title: const Text('实际提示词与输出协议'),
              children: [
                SelectableText('$_prompt\n$kAiEditContract\n$_protocol'),
              ],
            ),
            FilledButton(
              onPressed: _running ? null : _run,
              child: const Text('发送 AI 测试（消耗额度）'),
            ),
            if (_running)
              TextButton(
                onPressed: () {
                  if (_cancel?.isCompleted == false) _cancel!.complete();
                },
                child: const Text('取消测试'),
              ),
            const SizedBox(height: 16),
            TextField(
              controller: _json,
              enabled: !_running,
              minLines: 2,
              maxLines: 6,
              decoration: const InputDecoration(
                labelText: '粘贴模型 JSON 响应（可离线测试）',
                border: OutlineInputBorder(),
              ),
            ),
            OutlinedButton(
              onPressed: _running ? null : _validate,
              child: const Text('离线校验与替换预览'),
            ),
            if (_result != null)
              SelectableText(_result!, key: const ValueKey('developer-result')),
            if (_output != null) ...[
              const SizedBox(height: 12),
              const Text('修改后预览'),
              SelectableText(
                _output!,
                key: const ValueKey('developer-preview'),
              ),
            ],
            for (final span in _spans)
              ListTile(
                title: Text('${span.original} → ${span.replacement}'),
                subtitle: Text('${span.category} · ${span.reason}'),
              ),
            const Divider(height: 32),
            const Text('WebDAV 诊断（只读）'),
            ValueListenableBuilder<String>(
              valueListenable: WebDavSyncService.instance.status,
              builder: (context, status, _) => SelectableText(status),
            ),
            Text(
              WebDavSyncService.instance.config == null
                  ? '尚未配置 WebDAV'
                  : '自动同步：${WebDavSyncService.instance.config!.enabled ? '开启' : '关闭'}\n'
                        '规则：云端优先；删除已同步记录会上传。此处不执行同步或修改数据。',
            ),
            const SizedBox(height: 24),
          ],
        );
      },
    );
    return AppStyleTokens.of(context).isClassic
        ? SettingsScaffold(title: '开发者测试台', body: body)
        : ArchiveFeaturePage(
            title: '开发者测试台',
            code: 'DEVELOPER / SANDBOX',
            child: body,
          );
  }
}
