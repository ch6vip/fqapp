// 正文替换设置页（fqapp 专有功能，上游没有对应页面）。
//
// Chrome follows the ported Wenku8 settings vocabulary from revision ebcd7f1:
// ArchiveFeaturePage header, ContentPanel option panels, glass switches and
// archive icon actions. The rule model, evaluation engine and persistence are
// unchanged.
//
// Mechanical substitutions:
// - `SettingsScaffold` / `SettingsGroupCard` / `SettingsRow` / `SettingsSwitch`
//   -> `ArchiveFeaturePage`, `SettingsPanel`, `SettingsToggleRow`,
//   `GlassControls.toggle`.
// - `HomeStateView` -> `ContentNotice` (same title/message).
// - The fixed bottom action is a floating `GlassPillButton` over the list
//   because `ArchiveFeaturePage` has no bottomNavigationBar slot.

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../models/text_replacement_rule.dart';
import '../services/chapter_text_formatter.dart';
import '../services/text_replacement_engine.dart';
import '../services/text_replacement_store.dart';
import '../widgets/settings/settings_archive_rows.dart';
import '../widgets/wenku/wenku_ui.dart';

class TextReplacementPage extends StatefulWidget {
  const TextReplacementPage({super.key, this.store});
  final TextReplacementStore? store;
  @override
  State<TextReplacementPage> createState() => _TextReplacementPageState();
}

class _TextReplacementPageState extends State<TextReplacementPage> {
  TextReplacementStore get _store =>
      widget.store ?? TextReplacementStore.instance;
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _store.changes.addListener(_changed);
    _load();
  }

  Future<void> _load() async {
    await _store.load();
    if (mounted) setState(() => _loading = false);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _store.changes.removeListener(_changed);
    super.dispose();
  }

  Future<void> _save(List<TextReplacementRule> rules, {bool? enabled}) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await _store.save(
        enabled: enabled ?? _store.snapshot.enabled,
        rules: rules,
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _update(List<TextReplacementRule> rules, {bool? enabled}) async {
    try {
      await _save(rules, enabled: enabled);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_errorText(error))));
      }
    }
  }

  Future<void> _edit([int? index]) async {
    final existing = index == null ? null : _store.snapshot.rules[index];
    await showDialog<void>(
      context: context,
      builder: (_) => _RuleEditor(
        rule: existing,
        onSave: (rule) async {
          final rules = [..._store.snapshot.rules];
          if (index == null) {
            rules.add(rule);
          } else {
            rules[index] = rule;
          }
          await _save(rules);
        },
      ),
    );
  }

  Future<void> _move(int index, int direction) async {
    final rules = [..._store.snapshot.rules];
    final rule = rules.removeAt(index);
    rules.insert(index + direction, rule);
    await _update(rules);
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _store.snapshot;
    final full = snapshot.rules.length >= 50;
    return ArchiveFeaturePage(
      title: '正文替换',
      code: 'SYSTEM / TEXT REPLACEMENT',
      child: _loading
          ? const Center(child: CircularProgressIndicator())
          : Stack(
              children: [
                Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 760),
                    child: ListView(
                      padding: featurePadding(context).copyWith(
                        bottom: MediaQuery.paddingOf(context).bottom + 120,
                      ),
                      children: [
                        SettingsPanel(
                          children: [
                            SettingsToggleRow(
                              key: const ValueKey('replacement-enabled'),
                              icon: CupertinoIcons.textformat,
                              title: '启用正文替换',
                              description: '应用于所有小说，原始缓存保持不变',
                              value: snapshot.enabled,
                              onChanged: _saving
                                  ? null
                                  : (enabled) => _update(
                                      snapshot.rules,
                                      enabled: enabled,
                                    ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        const SettingsHint(
                          '规则从上到下执行，仅匹配每段正文。系统朗读使用替换后的文字，'
                          '真人音频保持原样。修改规则会停止当前系统朗读。',
                        ),
                        if (_store.warning case final warning?) ...[
                          const SizedBox(height: 8),
                          SettingsHint(warning),
                        ],
                        const SizedBox(height: 12),
                        if (snapshot.rules.isEmpty)
                          const ContentNotice(
                            icon: CupertinoIcons.doc_text,
                            title: '还没有替换规则',
                            message: '点击下方「添加规则」新增一条。',
                          )
                        else
                          SettingsPanel(
                            children: [
                              for (var i = 0; i < snapshot.rules.length; i++)
                                _ruleBlock(i, snapshot.rules[i]),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
                      child: Center(
                        child: GlassPillButton(
                          key: const ValueKey('replacement-add'),
                          icon: CupertinoIcons.add,
                          label: '添加规则',
                          onPressed: _loading || _saving || full ? null : _edit,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _ruleBlock(int i, TextReplacementRule rule) {
    return Column(
      children: [
        JellyTapSurface(
          key: ValueKey('replacement-edit-$i'),
          onTap: _saving ? null : () => _edit(i),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AppText(
                        rule.pattern,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 5),
                      AppText(
                        '${rule.isRegex ? '正则' : '普通文本'} → '
                        '${rule.replacement.isEmpty ? '（删除）' : rule.replacement}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.6,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Semantics(
                  label: '第 ${i + 1} 条规则启用',
                  child: GlassControls.toggle(
                    context,
                    value: rule.enabled,
                    onChanged: _saving
                        ? null
                        : (value) {
                            final rules = [..._store.snapshot.rules];
                            rules[i] = TextReplacementRule(
                              id: rule.id,
                              pattern: rule.pattern,
                              replacement: rule.replacement,
                              isRegex: rule.isRegex,
                              enabled: value,
                            );
                            _update(rules);
                          },
                  ),
                ),
              ],
            ),
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            GlassIconButton(
              key: ValueKey('replacement-up-$i'),
              icon: CupertinoIcons.chevron_up,
              label: '上移',
              onPressed: _saving || i == 0 ? null : () => _move(i, -1),
            ),
            const SizedBox(width: 4),
            GlassIconButton(
              key: ValueKey('replacement-down-$i'),
              icon: CupertinoIcons.chevron_down,
              label: '下移',
              onPressed: _saving || i == _store.snapshot.rules.length - 1
                  ? null
                  : () => _move(i, 1),
            ),
            const SizedBox(width: 4),
            GlassIconButton(
              key: ValueKey('replacement-delete-$i'),
              icon: CupertinoIcons.trash,
              label: '删除',
              onPressed: _saving
                  ? null
                  : () => _update([..._store.snapshot.rules]..removeAt(i)),
            ),
          ],
        ),
      ],
    );
  }
}

String _errorText(Object error) =>
    error is FormatException ? error.message : '替换规则保存失败，请重试';

class _RuleEditor extends StatefulWidget {
  const _RuleEditor({this.rule, required this.onSave});
  final TextReplacementRule? rule;
  final Future<void> Function(TextReplacementRule) onSave;
  @override
  State<_RuleEditor> createState() => _RuleEditorState();
}

class _RuleEditorState extends State<_RuleEditor> {
  late final _pattern = TextEditingController(text: widget.rule?.pattern ?? '');
  late final _value = TextEditingController(
    text: widget.rule?.replacement ?? '',
  );
  final _sample = TextEditingController();
  late bool _regex = widget.rule?.isRegex ?? false;
  late final String _id =
      widget.rule?.id ?? DateTime.now().microsecondsSinceEpoch.toString();
  bool _busy = false;
  String? _error, _preview;
  TextReplacementCancellation? _cancellation;

  TextReplacementRule get _rule => TextReplacementRule(
    id: _id,
    pattern: _pattern.text,
    replacement: _value.text,
    isRegex: _regex,
    enabled: widget.rule?.enabled ?? true,
  );

  @override
  void dispose() {
    _cancellation?.cancel();
    _pattern.dispose();
    _value.dispose();
    _sample.dispose();
    super.dispose();
  }

  Future<void> _run({required bool preview}) async {
    setState(() {
      _busy = true;
      _error = null;
      _preview = null;
    });
    try {
      final rule = _rule;
      await TextReplacementEngine.instance.validateRule(rule);
      if (!mounted) return;
      if (preview) {
        _cancellation = TextReplacementCancellation();
        final result = await TextReplacementEngine.instance.transform(
          source: ChapterContent.fromPlainText(_sample.text),
          chapterTitle: '',
          snapshot: TextReplacementSnapshot(
            enabled: true,
            rules: [
              TextReplacementRule(
                id: rule.id,
                pattern: rule.pattern,
                replacement: rule.replacement,
                isRegex: rule.isRegex,
              ),
            ],
          ),
          cancellation: _cancellation,
        );
        if (result.error != null) throw FormatException(result.error!);
        if (mounted) {
          setState(
            () => _preview = result.content.blocks
                .whereType<ChapterParagraph>()
                .map((p) => p.text)
                .join('\n'),
          );
        }
      } else {
        await widget.onSave(rule);
        if (mounted) Navigator.pop(context);
      }
    } catch (error) {
      if (mounted) setState(() => _error = _errorText(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.rule == null ? '添加规则' : '编辑规则'),
    content: SizedBox(
      width: 460,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const ValueKey('replacement-pattern'),
              controller: _pattern,
              enabled: !_busy,
              maxLength: 2048,
              decoration: const InputDecoration(labelText: '匹配内容'),
            ),
            TextField(
              key: const ValueKey('replacement-value'),
              controller: _value,
              enabled: !_busy,
              maxLength: 2048,
              decoration: const InputDecoration(
                labelText: '替换内容',
                helperText: '留空表示删除匹配文字',
              ),
            ),
            _regexToggle(context),
            if (_regex)
              const Text(r'使用 Dart 正则语法，仅匹配当前段落。替换支持 $0、$1…$99 和 $$。'),
            TextField(
              controller: _sample,
              enabled: !_busy,
              maxLines: 3,
              maxLength: 10000,
              decoration: const InputDecoration(labelText: '测试文本'),
            ),
            TextButton(
              onPressed: _busy ? null : () => _run(preview: true),
              child: const Text('预览本条规则'),
            ),
            if (_preview != null)
              SelectableText(_preview!.isEmpty ? '（替换结果为空）' : _preview!),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontWeight: FontWeight.w600,
                ),
              ),
            if (_busy) const LinearProgressIndicator(),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: _busy ? null : () => _run(preview: false),
        child: const Text('保存'),
      ),
    ],
  );

  Widget _regexToggle(BuildContext context) => Row(
    children: [
      Expanded(
        child: Text(
          '使用正则表达式',
          style: TextStyle(
            fontSize: 15,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
      ),
      GlassControls.toggle(
        context,
        value: _regex,
        semanticLabel: '使用正则表达式',
        onChanged: _busy ? null : (v) => setState(() => _regex = v),
      ),
    ],
  );
}
