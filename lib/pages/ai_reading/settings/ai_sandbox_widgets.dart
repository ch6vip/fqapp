import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../../services/ai_reading/ai_chapter_snapshot.dart';
import '../../../services/ai_reading/ai_models.dart';
import '../../../services/ai_reading/ai_protocol.dart';
import '../../../services/chapter_text_formatter.dart';
import '../../../widgets/app_ui/app_ui_scope.dart';
import '../../../widgets/home/home_design.dart';
import 'ai_sandbox_request_page.dart';
import 'ai_sandbox_style.dart';

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
    this.header,
    this.empty = false,
  });
  final Widget? header;
  final bool empty;
  final Widget input;
  final Widget result;
  // Resolve above AppFeaturePage: Scaffold changes the body MediaQuery in
  // classic mode, so reading featurePadding inside this layout counts chrome twice.
  final EdgeInsets padding;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final wide = constraints.maxWidth >= 720;
      final gutter = wide ? 28.0 : 16.0;
      return SingleChildScrollView(
        padding: padding.copyWith(left: gutter, right: gutter),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (header != null) ...[header!, const SizedBox(height: 6)],
            if (wide)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: input),
                  const SizedBox(width: 40),
                  Expanded(
                    child: empty
                        ? Container(
                            constraints: const BoxConstraints(minHeight: 400),
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              border: Border(
                                left: BorderSide(
                                  color: AiSandboxStyle(context).line,
                                ),
                              ),
                            ),
                            child: Text(
                              '测试结果将在这里显示',
                              style: TextStyle(
                                fontSize: 14,
                                color: HomePalette.of(context).muted,
                              ),
                            ),
                          )
                        : Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: result,
                          ),
                  ),
                ],
              )
            else ...[
              input,
              const SizedBox(height: 24),
              result,
            ],
          ],
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
                color: AiSandboxStyle(context).soft,
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
            style: AiSandboxStyle(context).textButton(),
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
    this.minLines = 7,
    this.monospace = false,
  });
  final String label;
  final TextEditingController controller;
  final Widget? action;
  final bool enabled;
  final int minLines;
  final bool monospace;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 42),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: HomePalette.of(context).ink,
                ),
              ),
            ),
            if (action != null)
              Expanded(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: TextButtonTheme(
                    data: TextButtonThemeData(
                      style: AiSandboxStyle(
                        context,
                      ).textButton(muted: true, size: 12),
                    ),
                    child: action!,
                  ),
                ),
              ),
          ],
        ),
      ),
      AiSandboxPanel(
        padding: const EdgeInsets.all(14),
        child: TextField(
          controller: controller,
          enabled: enabled,
          minLines: minLines,
          maxLines: null,
          keyboardType: TextInputType.multiline,
          style: TextStyle(
            color: HomePalette.of(context).ink,
            fontSize: monospace ? 13 : 15,
            height: monospace ? 1.65 : 1.75,
            fontFamily: monospace ? 'monospace' : null,
          ),
          decoration: InputDecoration(
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            disabledBorder: InputBorder.none,
            contentPadding: EdgeInsets.zero,
            filled: false,
            isDense: true,
            hintText: label,
            constraints: BoxConstraints(
              minHeight: MediaQuery.sizeOf(context).width >= 720
                  ? (minLines == 4 ? 114 : 210)
                  : 0,
            ),
          ),
        ),
      ),
    ],
  );
}

/// A 48dp touch area around the prototype's compact 48 × 28 switch.
class AiSandboxRestoreOption extends StatelessWidget {
  const AiSandboxRestoreOption({
    super.key,
    required this.value,
    required this.onChanged,
  });
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final style = AiSandboxStyle(context);
    final muted = style.palette.muted;
    return Semantics(
      label: '去屏蔽词',
      onTap: onChanged == null ? null : () => onChanged!(!value),
      toggled: value,
      enabled: onChanged != null,
      child: InkWell(
        onTap: onChanged == null ? null : () => onChanged!(!value),
        excludeFromSemantics: true,
        child: ExcludeSemantics(
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 64),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '去屏蔽词',
                    style: TextStyle(fontSize: 14, color: style.palette.ink),
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 48,
                  height: 48,
                  child: Center(
                    child: Opacity(
                      opacity: onChanged == null ? .45 : 1,
                      child: Container(
                        width: 48,
                        height: 28,
                        decoration: BoxDecoration(
                          color: value ? style.primary : style.soft,
                          border: Border.all(
                            color: value ? style.primary : muted,
                            width: 2,
                          ),
                          borderRadius: BorderRadius.circular(30),
                        ),
                        child: Stack(
                          children: [
                            Positioned(
                              left: value ? 22 : 4,
                              top: value ? 2 : 4,
                              child: Container(
                                width: value ? 20 : 16,
                                height: value ? 20 : 16,
                                decoration: BoxDecoration(
                                  color: value ? Colors.white : muted,
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
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
            backgroundColor: AiSandboxStyle(context).highlight,
            color: palette.ink,
            decoration: TextDecoration.underline,
            decorationColor: AiSandboxStyle(context).primary,
            decorationThickness: 1,
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

  Widget _error(
    BuildContext context,
    String title,
    String body, {
    String? code,
  }) {
    final style = AiSandboxStyle(context);
    return Container(
      margin: const EdgeInsets.only(top: 8, bottom: 16),
      padding: const EdgeInsets.fromLTRB(12, 2, 0, 2),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: style.error, width: 2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: style.error,
            ),
          ),
          const SizedBox(height: 5),
          SelectableText(
            body,
            style: TextStyle(
              fontSize: 13,
              height: 1.6,
              color: style.palette.muted,
            ),
          ),
          if (code != null) ...[
            const SizedBox(height: 6),
            SelectableText(
              code,
              style: TextStyle(
                fontSize: 12,
                fontFamily: 'monospace',
                color: style.palette.ink,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _pair(
    BuildContext context,
    String label,
    String text, {
    bool old = false,
  }) {
    final palette = HomePalette.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: MediaQuery.textScalerOf(context).scale(36),
          child: Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              label,
              style: TextStyle(fontSize: 12, height: 1.6, color: palette.muted),
            ),
          ),
        ),
        Expanded(
          child: SelectableText(
            text,
            style: TextStyle(
              fontSize: 14,
              height: 1.6,
              color: old ? palette.muted : palette.ink,
              fontWeight: old ? FontWeight.normal : FontWeight.w500,
              decoration: old ? TextDecoration.lineThrough : null,
              decorationColor: AiSandboxStyle(context).line,
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final result = widget.result;
    if (result == null) return const SizedBox.shrink();
    final style = AiSandboxStyle(context);
    final palette = style.palette;
    final validation = result.validation;
    final valid = validation?.valid == true;
    final showRawTab =
        result.raw != null &&
        (result.request != null || widget.onValidate != null);
    final labels = valid
        ? ['正文预览', '修改详情', if (showRawTab) '原始 JSON']
        : <String>[];
    final muted = TextStyle(fontSize: 12, height: 1.5, color: palette.muted);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 32),
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 4,
            children: [
              if (widget.previous) Text('上次结果', style: muted),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (valid) ...[
                    ExcludeSemantics(
                      child: Icon(
                        LucideIcons.circle_check,
                        size: 18,
                        color: style.success,
                      ),
                    ),
                    const SizedBox(width: 7),
                  ],
                  Flexible(
                    child: Text(
                      result.title,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: palette.ink,
                      ),
                    ),
                  ),
                ],
              ),
              if (result.elapsed != null)
                Text(
                  '${(result.elapsed!.inMilliseconds / 1000).toStringAsFixed(1)} s',
                  style: muted,
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 5, bottom: 14),
          child: DefaultTextStyle(
            style: muted,
            child: Wrap(
              spacing: 16,
              runSpacing: 4,
              children: [
                if (valid) Text('${validation!.spans.length} 处修改'),
                if (result.requests != null) Text('${result.requests} 次请求'),
                if (result.usage != null) Text(_usage(result.usage!)),
              ],
            ),
          ),
        ),
        if (result.message != null)
          _error(
            context,
            result.request == null ? '请检查响应内容' : '请求未完成',
            result.message!,
          ),
        if (validation != null && !valid)
          for (final issue in validation.errors)
            _error(
              context,
              '请检查响应内容',
              [
                if (issue.path != null) issue.path!,
                if (issue.editIndex != null) '第 ${issue.editIndex! + 1} 条修改',
                if (issue.editIndices.isNotEmpty)
                  '修改 ${issue.editIndices.map((i) => i + 1).join('、')}',
                if (issue.start != null)
                  '位置 ${issue.start! + 1}${issue.end == null ? '' : '–${issue.end}'}',
                if (issue.detailKey != null) issue.detailKey!,
                if (issue.occurrences != null) '匹配 ${issue.occurrences} 处',
              ].join(' · '),
              code: issue.code,
            ),
        if (valid) ...[
          DefaultTabController(
            key: ObjectKey(result),
            length: labels.length,
            child: AiSandboxTabs(
              labels: labels,
              onTap: (value) => setState(() => _tab = value),
            ),
          ),
          const SizedBox(height: 14),
        ],
        if (_tab == 2 || !valid) ...[
          if (result.raw != null)
            AiSandboxPanel(
              raw: true,
              padding: const EdgeInsets.all(12),
              child: SelectableText(
                result.raw!,
                key: const ValueKey('sandbox-raw'),
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  height: 1.65,
                  color: palette.ink,
                ),
              ),
            ),
        ] else if (_tab == 0)
          _preview(context, result)
        else if (validation!.spans.isEmpty)
          Text(
            '没有修改。',
            style: TextStyle(fontSize: 14, height: 1.7, color: palette.muted),
          )
        else
          for (final (index, span) in validation.spans.indexed)
            Container(
              margin: EdgeInsets.only(
                bottom: index == validation.spans.length - 1 ? 0 : 16,
              ),
              padding: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                border: index == validation.spans.length - 1
                    ? null
                    : Border(bottom: BorderSide(color: style.line)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '${index + 1} / ${validation.spans.length}　${span.category}',
                    style: muted,
                  ),
                  const SizedBox(height: 8),
                  _pair(context, '原文', span.original, old: true),
                  const SizedBox(height: 6),
                  _pair(
                    context,
                    '修改',
                    span.isDeletion ? '删除' : span.replacement,
                  ),
                  const SizedBox(height: 9),
                  SelectableText(
                    span.reason,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.6,
                      color: palette.muted,
                    ),
                  ),
                ],
              ),
            ),
        if ((_tab == 2 || !valid) &&
            widget.onValidate != null &&
            result.raw != null)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: widget.onValidate,
              style: style.textButton(),
              child: const Text('用于 JSON 校验'),
            ),
          ),
        if (result.request case final request?)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  '${request.settings.modelId ?? '未选择模型'} · ${request.behaviorSource} · 去屏蔽词${request.restore ? '开启' : '关闭'}',
                  key: const ValueKey('sandbox-result-config'),
                  style: muted,
                ),
                if (widget.onViewRequest != null && (result.requests ?? 0) > 0)
                  TextButton(
                    onPressed: widget.onViewRequest,
                    style: style.textButton(size: 12),
                    child: const Text('查看本次请求'),
                  ),
              ],
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
