// 正文替换设置页（fqapp 专有功能，上游没有对应页面）。
//
// Two presentations, one rule model. Classic restores the pre-#291
// `settingsAppBar` layout from fqapp-backup@f329399 (`SettingsGroupCard` +
// `SettingsRow` + `SettingsSwitch`, full-width add button in the bottom bar);
// archive keeps the Wenku8 rev ebcd7f1 surfaces (`ArchiveFeaturePage`,
// `ContentPanel`, `GlassTextButton`-style rows, floating `GlassPillButton`).
//
// `TextReplacementStore` / `TextReplacementEngine` and the save/rollback
// behaviour are unchanged; `SettingsToggleRow` and the rule rows own the
// classic presentation, so both styles share the same callbacks.

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/text_replacement_rule.dart';
import '../services/chapter_text_formatter.dart';
import '../services/text_replacement_engine.dart';
import '../services/text_replacement_store.dart';
import '../services/app_theme_style.dart';
import '../widgets/app_ui/app_ui_scope.dart';
import '../widgets/home/home_design.dart';
import '../widgets/settings/settings_adaptive.dart';
import '../widgets/settings/settings_archive_page.dart';
import '../widgets/settings/settings_archive_rows.dart';
import '../widgets/settings/settings_scroll_anchor.dart';
import '../widgets/settings/settings_widgets.dart';
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

  /// One list for both presentations: the shell swaps around it, so the scroll
  /// position and the remembered section survive a style switch.
  final _scroll = ScrollController();
  late final _anchor = SettingsScrollAnchor(_scroll);

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
    _anchor.dispose();
    _scroll.dispose();
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
    final style = AppUiScope.of(context);
    final classic = style == AppThemeStyle.classic;
    _anchor.track(style);
    final snapshot = _store.snapshot;
    final full = snapshot.rules.length >= 50;
    final content = <Widget>[
      KeyedSubtree(
        key: _anchor.keyFor('enabled'),
        child: SettingsCard(
          children: [
            SettingsToggleRow(
              key: const ValueKey('replacement-enabled'),
              icon: CupertinoIcons.textformat,
              title: '启用正文替换',
              description: '应用于所有小说，原始缓存保持不变',
              value: snapshot.enabled,
              onChanged: _saving
                  ? null
                  : (enabled) => _update(snapshot.rules, enabled: enabled),
            ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      const SettingsHint(
        '规则从上到下执行，仅匹配每段正文。系统朗读使用替换后的文字，'
        '真人音频保持原样。修改规则会停止当前系统朗读。',
      ),
      if (_store.warning case final warning?) ...[
        const SizedBox(height: 8),
        SettingsHint(warning, emphasis: true),
      ],
      const SizedBox(height: 12),
      KeyedSubtree(
        key: _anchor.keyFor('rules'),
        child: snapshot.rules.isEmpty
            ? const SettingsNotice(
                icon: CupertinoIcons.doc_text,
                classicIcon: LucideIcons.file_text,
                title: '还没有替换规则',
                message: '点击下方「添加规则」新增一条。',
              )
            : SettingsCard(
                children: [
                  // One anchor per rule: the row the user was reading keeps
                  // its place even though classic and archive rows differ in
                  // height.
                  for (var i = 0; i < snapshot.rules.length; i++)
                    KeyedSubtree(
                      key: _anchor.keyFor('rule-${snapshot.rules[i].id}'),
                      child: _ruleBlock(i, snapshot.rules[i], classic: classic),
                    ),
                ],
              ),
      ),
    ];
    return SettingsArchivePage(
      title: '正文替换',
      code: 'SYSTEM / TEXT REPLACEMENT',
      // Classic pins the add button to the bottom edge like the pre-#291 page;
      // the archive keeps the floating pill inside the body.
      classicBottomBar: classic ? _classicAddBar(context) : null,
      child: _loading
          ? const Center(child: CircularProgressIndicator())
          : Stack(
              children: [
                Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: classic ? 640 : 760),
                    child: ListView(
                      key: const ValueKey('text-replacement-list'),
                      controller: _scroll,
                      padding: classic
                          ? featurePadding(context)
                          : featurePadding(context).copyWith(
                              bottom:
                                  MediaQuery.paddingOf(context).bottom + 120,
                            ),
                      children: content,
                    ),
                  ),
                ),
                if (!classic)
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
                            onPressed: _loading || _saving || full
                                ? null
                                : _edit,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }

  /// Classic fixed action bar (pre-#291 layout). The archive keeps the pill.
  Widget _classicAddBar(BuildContext context) {
    final palette = HomePalette.of(context);
    final full = _store.snapshot.rules.length >= 50;
    return SafeArea(
      top: false,
      child: Container(
        color: palette.canvas,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: SettingsAction(
          key: const ValueKey('replacement-add'),
          label: '添加规则',
          icon: LucideIcons.plus,
          style: SettingsActionStyle.filled,
          expand: true,
          onPressed: _loading || _saving || full ? null : _edit,
        ),
      ),
    );
  }

  Widget _ruleBlock(int i, TextReplacementRule rule, {required bool classic}) {
    final palette = HomePalette.of(context);
    final enabledToggle = classic
        ? SettingsSwitch(
            value: rule.enabled,
            semanticLabel: '第 ${i + 1} 条规则启用',
            onChanged: _saving
                ? null
                : (value) => _updateRule(i, rule, enabled: value),
          )
        : GlassControls.toggle(
            context,
            value: rule.enabled,
            semanticLabel: '第 ${i + 1} 条规则启用',
            onChanged: _saving
                ? null
                : (value) => _updateRule(i, rule, enabled: value),
          );
    final actions = classic
        ? Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              IconButton(
                key: ValueKey('replacement-up-$i'),
                tooltip: '上移',
                color: palette.muted,
                onPressed: _saving || i == 0 ? null : () => _move(i, -1),
                icon: const Icon(LucideIcons.arrow_up, size: 18),
              ),
              IconButton(
                key: ValueKey('replacement-down-$i'),
                tooltip: '下移',
                color: palette.muted,
                onPressed: _saving || i == _store.snapshot.rules.length - 1
                    ? null
                    : () => _move(i, 1),
                icon: const Icon(LucideIcons.arrow_down, size: 18),
              ),
              IconButton(
                key: ValueKey('replacement-delete-$i'),
                tooltip: '删除',
                color: palette.muted,
                onPressed: _saving
                    ? null
                    : () => _update([..._store.snapshot.rules]..removeAt(i)),
                icon: const Icon(LucideIcons.trash, size: 18),
              ),
            ],
          )
        : Row(
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
          );
    if (classic) {
      return Column(
        children: [
          SettingsRow(
            key: ValueKey('replacement-edit-$i'),
            title: rule.pattern,
            subtitle:
                '${rule.isRegex ? '正则' : '普通文本'} → '
                '${rule.replacement.isEmpty ? '（删除）' : rule.replacement}',
            trailing: enabledToggle,
            onTap: _saving ? null : () => _edit(i),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
            child: actions,
          ),
        ],
      );
    }
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
                enabledToggle,
              ],
            ),
          ),
        ),
        actions,
      ],
    );
  }

  /// Toggle one rule's enabled flag without rewriting the whole model.
  void _updateRule(
    int index,
    TextReplacementRule rule, {
    required bool enabled,
  }) {
    final rules = [..._store.snapshot.rules];
    rules[index] = TextReplacementRule(
      id: rule.id,
      pattern: rule.pattern,
      replacement: rule.replacement,
      isRegex: rule.isRegex,
      enabled: enabled,
    );
    _update(rules);
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
                  color: AppUiScope.isClassic(context)
                      ? HomePalette.of(context).accentText
                      : Theme.of(context).colorScheme.error,
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

  Widget _regexToggle(BuildContext context) {
    final classic = AppUiScope.isClassic(context);
    final onChanged = _busy ? null : (bool v) => setState(() => _regex = v);
    return Row(
      children: [
        Expanded(
          child: Text(
            '使用正则表达式',
            style: TextStyle(
              fontSize: 15,
              color: classic
                  ? HomePalette.of(context).ink
                  : Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ),
        if (classic)
          SettingsSwitch(
            value: _regex,
            semanticLabel: '使用正则表达式',
            onChanged: onChanged,
          )
        else
          GlassControls.toggle(
            context,
            value: _regex,
            semanticLabel: '使用正则表达式',
            onChanged: onChanged,
          ),
      ],
    );
  }
}
