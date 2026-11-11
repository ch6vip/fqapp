import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../../services/ai_reading/ai_chapter_snapshot.dart';
import '../../../services/ai_reading/ai_models.dart';
import '../../../services/ai_reading/ai_protocol.dart';
import '../../../services/chapter_text_formatter.dart';
import '../../../widgets/app_ui/app_ui_scope.dart';
import '../../../widgets/home/home_design.dart';
import '../../../widgets/settings/settings_widgets.dart';
import 'ai_sandbox_request_page.dart';

const aiSandboxSample = '他以经在门口等了半个小时。\n“我踏马真是服了。”他叹了口气。\n他拿出手机，打开*****给朋友发消息。';
const aiSandboxExampleResponse =
    '{"edits":[{"original":"以经","replacement":"已经","category":"错别字","reason":"“已经”表示动作完成或时间经过。"}]}';

ChapterContent aiSandboxContent(String text) => ChapterContent(
  blocks: [
    for (final line in text.split(RegExp(r'\r?\n')))
      if (line.trim().isNotEmpty) ChapterParagraph(line),
  ],
);

/// Each result retains the source it validated, independently of editor drafts.
class AiSandboxResult {
  const AiSandboxResult({
    required this.title,
    required this.source,
    this.raw,
    this.validation,
    this.message,
    this.elapsed,
    this.requests,
    this.usage,
    this.request,
  });
  final String title;
  final String source;
  final String? raw;
  final AiValidationResult? validation;
  final String? message;
  final Duration? elapsed;
  final int? requests;
  final AiUsage? usage;
  final AiSandboxRequest? request;
}

class AiSandboxLayout extends StatelessWidget {
  const AiSandboxLayout({
    super.key,
    required this.input,
    required this.result,
    required this.padding,
  });
  final Widget input;
  final Widget result;
  // Resolve above AppFeaturePage: Scaffold changes the body MediaQuery in
  // classic mode, so reading featurePadding inside this layout counts chrome twice.
  final EdgeInsets padding;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final wide = constraints.maxWidth >= 720;
      return SingleChildScrollView(
        padding: padding,
        child: wide
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: input),
                  const SizedBox(width: 32),
                  Expanded(child: result),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [input, const SizedBox(height: 24), result],
              ),
      );
    },
  );
}

class AiSandboxProviderSummary extends StatelessWidget {
  const AiSandboxProviderSummary({
    super.key,
    required this.provider,
    required this.model,
    required this.onViewRequest,
  });

  final String provider;
  final String model;
  final VoidCallback onViewRequest;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return ConstrainedBox(
      key: const ValueKey('sandbox-provider-summary'),
      constraints: const BoxConstraints(minHeight: 44),
      child: Row(
        children: [
          ExcludeSemantics(
            child: Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: palette.soft,
                borderRadius: BorderRadius.circular(
                  AppUiScope.isClassic(context) ? 9 : 4,
                ),
              ),
              child: Icon(LucideIcons.sparkle, size: 17, color: palette.muted),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Tooltip(
              message: '$provider\n$model',
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    provider,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: palette.ink,
                      fontSize: 13,
                      height: 1.4,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    model,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: palette.muted,
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: onViewRequest,
            style: TextButton.styleFrom(
              textStyle: const TextStyle(fontSize: 13),
            ),
            child: const Text('查看请求'),
          ),
        ],
      ),
    );
  }
}

class AiSandboxField extends StatelessWidget {
  const AiSandboxField({
    super.key,
    required this.label,
    required this.controller,
    this.action,
    this.enabled = true,
    this.minLines = 6,
  });
  final String label;
  final TextEditingController controller;
  final Widget? action;
  final bool enabled;
  final int minLines;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
          ?action,
        ],
      ),
      const SizedBox(height: 8),
      SurfacePanel(
        padding: const EdgeInsets.all(14),
        child: TextField(
          controller: controller,
          enabled: enabled,
          minLines: minLines,
          maxLines: null,
          keyboardType: TextInputType.multiline,
          style: const TextStyle(fontSize: 15, height: 1.75),
          decoration: InputDecoration(
            border: InputBorder.none,
            isDense: true,
            hintText: label,
          ),
        ),
      ),
    ],
  );
}

class AiSandboxResultView extends StatefulWidget {
  const AiSandboxResultView({
    super.key,
    this.result,
    this.onValidate,
    this.onViewRequest,
    this.previous = false,
  });
  final AiSandboxResult? result;
  final VoidCallback? onValidate;
  final VoidCallback? onViewRequest;
  final bool previous;
  @override
  State<AiSandboxResultView> createState() => _AiSandboxResultViewState();
}

class _AiSandboxResultViewState extends State<AiSandboxResultView> {
  int _tab = 0;
  @override
  void didUpdateWidget(covariant AiSandboxResultView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.result, widget.result)) _tab = 0;
  }

  Widget _preview(BuildContext context, AiSandboxResult result) {
    final palette = HomePalette.of(context);
    final spans = [...result.validation!.spans]
      ..sort((a, b) => a.sourceStart.compareTo(b.sourceStart));
    final children = <InlineSpan>[];
    var cursor = 0;
    for (final span in spans) {
      children.add(
        TextSpan(text: result.source.substring(cursor, span.sourceStart)),
      );
      children.add(
        TextSpan(
          text: span.isDeletion ? '│' : span.replacement,
          semanticsLabel: span.isDeletion
              ? '删除：${span.original}'
              : span.replacement,
          style: TextStyle(
            backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
            color: palette.ink,
            decoration: TextDecoration.underline,
          ),
        ),
      );
      cursor = span.sourceEnd;
    }
    children.add(TextSpan(text: result.source.substring(cursor)));
    return SelectableText.rich(
      TextSpan(children: children),
      key: const ValueKey('sandbox-preview'),
      style: TextStyle(color: palette.ink, fontSize: 15, height: 1.95),
    );
  }

  String _usage(AiUsage usage) {
    if (!usage.hasAnyKnown) return 'Token 用量未知';
    if (usage.status == AiUsageStatus.known) {
      return '${usage.knownTokenSum} tokens';
    }
    return '部分 Token 用量：输入 ${usage.promptTokens ?? '未知'} / 输出 ${usage.completionTokens ?? '未知'}'
        '${usage.cachedTokens == null ? '' : ' / 缓存 ${usage.cachedTokens}'}'
        '${usage.reasoningTokens == null ? '' : ' / 思考 ${usage.reasoningTokens}'}';
  }

  @override
  Widget build(BuildContext context) {
    final result = widget.result;
    if (result == null) return const SizedBox.shrink();
    final validation = result.validation;
    final valid = validation?.valid == true;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          spacing: 12,
          children: [
            if (widget.previous) const Text('上次结果'),
            Text(
              result.title,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            if (result.elapsed != null)
              Text(
                '${(result.elapsed!.inMilliseconds / 1000).toStringAsFixed(1)} s',
              ),
          ],
        ),
        if (result.request case final request?)
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                '${request.settings.modelId ?? '未选择模型'} · ${request.behaviorSource} · 去屏蔽词${request.restore ? '开启' : '关闭'}',
                key: const ValueKey('sandbox-result-config'),
                style: TextStyle(
                  fontSize: 12,
                  color: HomePalette.of(context).muted,
                ),
              ),
              if (widget.onViewRequest != null && (result.requests ?? 0) > 0)
                TextButton(
                  onPressed: widget.onViewRequest,
                  child: const Text('查看本次请求'),
                ),
            ],
          ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 16,
          runSpacing: 8,
          children: [
            if (valid) Text('${validation!.spans.length} 处修改'),
            if (result.requests != null) Text('${result.requests} 次请求'),
            if (result.usage != null) Text(_usage(result.usage!)),
          ],
        ),
        if (result.message != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: SelectableText(result.message!),
          ),
        if (validation != null && !valid)
          for (final issue in validation.errors)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: SelectableText(
                [
                  issue.code,
                  if (issue.path != null) issue.path!,
                  if (issue.editIndex != null) '第 ${issue.editIndex! + 1} 条修改',
                  if (issue.editIndices.isNotEmpty)
                    '修改 ${issue.editIndices.map((i) => i + 1).join('、')}',
                  if (issue.start != null)
                    '位置 ${issue.start! + 1}${issue.end == null ? '' : '–${issue.end}'}',
                  if (issue.detailKey != null) issue.detailKey!,
                  if (issue.occurrences != null) '匹配 ${issue.occurrences} 处',
                ].join(' · '),
              ),
            ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          children: [
            if (valid)
              TextButton(
                onPressed: () => setState(() => _tab = 0),
                child: Text(
                  '正文预览',
                  style: TextStyle(
                    fontWeight: _tab == 0 ? FontWeight.bold : null,
                  ),
                ),
              ),
            if (valid)
              TextButton(
                onPressed: () => setState(() => _tab = 1),
                child: Text(
                  '修改详情',
                  style: TextStyle(
                    fontWeight: _tab == 1 ? FontWeight.bold : null,
                  ),
                ),
              ),
            if (result.raw != null)
              TextButton(
                onPressed: () => setState(() => _tab = 2),
                child: Text(
                  '原始 JSON',
                  style: TextStyle(
                    fontWeight: _tab == 2 ? FontWeight.bold : null,
                  ),
                ),
              ),
          ],
        ),
        const Divider(),
        if (_tab == 2 || !valid) ...[
          if (result.raw != null)
            SelectableText(
              result.raw!,
              key: const ValueKey('sandbox-raw'),
              style: const TextStyle(fontSize: 13, height: 1.65),
            ),
        ] else if (_tab == 0)
          _preview(context, result)
        else if (validation!.spans.isEmpty)
          const Text('没有修改。')
        else
          for (final span in validation.spans)
            Padding(
              padding: const EdgeInsets.only(bottom: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    span.category,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  SelectableText('原文  ${span.original}'),
                  SelectableText(
                    '修改  ${span.isDeletion ? '删除' : span.replacement}',
                  ),
                  const SizedBox(height: 8),
                  SelectableText(span.reason),
                  const Divider(),
                ],
              ),
            ),
        if (widget.onValidate != null && result.raw != null)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: widget.onValidate,
              child: const Text('用于 JSON 校验'),
            ),
          ),
      ],
    );
  }
}

AiSandboxResult aiSandboxValidate(String source, String raw) {
  if (source.trim().isEmpty) {
    return AiSandboxResult(
      title: '校验未通过',
      source: source,
      raw: raw,
      message: 'ORIGINAL_REQUIRED · 请填写原文',
    );
  }
  try {
    final snapshot = AiChapterSnapshotBuilder.fromContent(
      aiSandboxContent(source),
      '',
    );
    final validation = const AiValidator().validateContent(raw, snapshot);
    return AiSandboxResult(
      title: validation.valid ? '校验通过' : '校验未通过',
      source: snapshot.requestText,
      raw: raw,
      validation: validation,
    );
  } on AiSnapshotException catch (error) {
    return AiSandboxResult(
      title: '校验未通过',
      source: source,
      raw: raw,
      message: 'SNAPSHOT_INVALID · ${error.message}',
    );
  }
}
