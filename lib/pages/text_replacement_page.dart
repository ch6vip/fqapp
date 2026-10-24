import 'package:flutter/material.dart';

import '../models/text_replacement_rule.dart';
import '../services/chapter_text_formatter.dart';
import '../services/text_replacement_engine.dart';
import '../services/text_replacement_store.dart';
import '../widgets/home/home_design.dart';

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
    final palette = HomePalette.of(context);
    final snapshot = _store.snapshot;
    return Scaffold(
      backgroundColor: palette.canvas,
      appBar: AppBar(title: const Text('正文替换')),
      floatingActionButton: FloatingActionButton(
        key: const ValueKey('replacement-add'),
        onPressed: _loading || _saving || snapshot.rules.length >= 50
            ? null
            : _edit,
        child: const Icon(Icons.add),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
              children: [
                SwitchListTile(
                  key: const ValueKey('replacement-enabled'),
                  title: const Text('启用正文替换'),
                  subtitle: const Text('应用于所有小说，原始缓存保持不变'),
                  value: snapshot.enabled,
                  onChanged: _saving
                      ? null
                      : (enabled) => _update(snapshot.rules, enabled: enabled),
                ),
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    '规则从上到下执行，仅匹配每段正文。系统朗读使用替换后的文字，真人音频保持原样。修改规则会停止当前系统朗读。',
                  ),
                ),
                if (_store.warning != null)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(_store.warning!),
                  ),
                if (snapshot.rules.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('还没有替换规则，点击下方加号添加。'),
                  ),
                for (var i = 0; i < snapshot.rules.length; i++)
                  Card(
                    color: palette.surface,
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          ListTile(
                            key: ValueKey('replacement-edit-$i'),
                            title: Text(
                              snapshot.rules[i].pattern,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              '${snapshot.rules[i].isRegex ? '正则' : '普通文本'} → ${snapshot.rules[i].replacement.isEmpty ? '（删除）' : snapshot.rules[i].replacement}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: _saving ? null : () => _edit(i),
                            trailing: Switch(
                              value: snapshot.rules[i].enabled,
                              onChanged: _saving
                                  ? null
                                  : (value) {
                                      final old = snapshot.rules[i];
                                      final rules = [...snapshot.rules];
                                      rules[i] = TextReplacementRule(
                                        id: old.id,
                                        pattern: old.pattern,
                                        replacement: old.replacement,
                                        isRegex: old.isRegex,
                                        enabled: value,
                                      );
                                      _update(rules);
                                    },
                            ),
                          ),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              IconButton(
                                key: ValueKey('replacement-up-$i'),
                                tooltip: '上移',
                                onPressed: _saving || i == 0
                                    ? null
                                    : () => _move(i, -1),
                                icon: const Icon(Icons.arrow_upward),
                              ),
                              IconButton(
                                key: ValueKey('replacement-down-$i'),
                                tooltip: '下移',
                                onPressed:
                                    _saving || i == snapshot.rules.length - 1
                                    ? null
                                    : () => _move(i, 1),
                                icon: const Icon(Icons.arrow_downward),
                              ),
                              IconButton(
                                key: ValueKey('replacement-delete-$i'),
                                tooltip: '删除',
                                onPressed: _saving
                                    ? null
                                    : () => _update(
                                        [...snapshot.rules]..removeAt(i),
                                      ),
                                icon: const Icon(Icons.delete_outline),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
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
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('使用正则表达式'),
              value: _regex,
              onChanged: _busy ? null : (v) => setState(() => _regex = v),
            ),
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
                style: TextStyle(color: Theme.of(context).colorScheme.error),
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
}
