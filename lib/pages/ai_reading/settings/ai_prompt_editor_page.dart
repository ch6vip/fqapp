import 'package:flutter/material.dart';

import '../../../widgets/home/home_design.dart';
import '../../../widgets/settings/settings_widgets.dart';
import '../../../widgets/wenku/wenku_ui.dart';
import 'ai_sandbox_style.dart';

/// Full-page prompt editor. The old dialog was too small for a prompt that is
/// normally several screens long; this keeps the whole page scrollable while
/// the AppBar save action stays reachable.
class AiPromptEditorPage extends StatefulWidget {
  const AiPromptEditorPage({
    super.key,
    required this.title,
    required this.initial,
    this.hint,
    this.allowEmpty = false,
    this.actionLabel = '保存',
    this.restoreText,
  });

  final String title;
  final String initial;
  final String? hint;

  /// Global prompts use an empty string to mean「内置默认」. Book prompts must
  /// contain something because they are an explicit override.
  final bool allowEmpty;
  final String actionLabel;
  final String? restoreText;

  @override
  State<AiPromptEditorPage> createState() => _AiPromptEditorPageState();
}

class _AiPromptEditorPageState extends State<AiPromptEditorPage> {
  late final TextEditingController _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initial)
      ..addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_onTextChanged)
      ..dispose();
    super.dispose();
  }

  void _onTextChanged() {
    if (!mounted) return;
    setState(() {
      if (_error != null) _error = null;
    });
  }

  void _save() {
    final text = _controller.text;
    if (!widget.allowEmpty && text.trim().isEmpty) {
      setState(() => _error = '提示词不能为空');
      return;
    }
    Navigator.of(context).pop(text);
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final hint = widget.hint;
    final sandbox = widget.restoreText != null;
    final sandboxStyle = AiSandboxStyle(context);
    final editor = TextField(
      controller: _controller,
      maxLines: null,
      expands: true,
      textAlignVertical: TextAlignVertical.top,
      keyboardType: TextInputType.multiline,
      style: sandbox
          ? TextStyle(fontSize: 15, height: 1.8, color: palette.ink)
          : null,
      decoration: InputDecoration(
        border: InputBorder.none,
        enabledBorder: sandbox ? InputBorder.none : null,
        focusedBorder: sandbox ? InputBorder.none : null,
        contentPadding: sandbox ? EdgeInsets.zero : null,
        filled: sandbox ? false : null,
        isDense: true,
      ),
    );
    final body = SafeArea(
      top: widget.restoreText == null,
      child: Padding(
        padding: widget.restoreText == null
            ? const EdgeInsets.fromLTRB(16, 8, 16, 12)
            : EdgeInsets.fromLTRB(
                16,
                MediaQuery.paddingOf(context).top +
                    FrostedHeader.toolbarHeight +
                    16,
                16,
                16,
              ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (hint != null) ...[
              Text(
                hint,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.4,
                  color: palette.muted,
                ),
              ),
              const SizedBox(height: 8),
            ],
            Expanded(
              child: sandbox
                  ? AiSandboxPanel(
                      key: const ValueKey('sandbox-prompt-panel'),
                      child: editor,
                    )
                  : SurfacePanel(
                      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
                      child: editor,
                    ),
            ),
            SizedBox(height: sandbox ? 12 : 6),
            if (sandbox && _error != null) ...[
              Text(
                _error!,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.5,
                  color: sandboxStyle.error,
                ),
              ),
              const SizedBox(height: 8),
            ],
            if (sandbox)
              ConstrainedBox(
                key: const ValueKey('sandbox-prompt-toolbar'),
                constraints: const BoxConstraints(minHeight: 44),
                child: Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    TextButton(
                      onPressed: () => _controller.text = widget.restoreText!,
                      style: sandboxStyle.textButton(),
                      child: const Text('恢复全局'),
                    ),
                    Text(
                      '${_controller.text.characters.length} 字',
                      style: TextStyle(fontSize: 12, color: palette.muted),
                    ),
                  ],
                ),
              )
            else
              Row(
                children: [
                  if (_error case final error?)
                    Expanded(
                      child: Text(
                        error,
                        style: TextStyle(
                          fontSize: 12,
                          color: palette.eink
                              ? Colors.black
                              : const Color(0xFF9C3D33),
                        ),
                      ),
                    )
                  else
                    const Spacer(),
                  Text(
                    '${_controller.text.characters.length} 字符',
                    style: TextStyle(fontSize: 12, color: palette.muted),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
    final actions = [
      TextButton(
        onPressed: _save,
        style: sandbox ? sandboxStyle.textButton() : null,
        child: Text(widget.actionLabel),
      ),
    ];
    return widget.restoreText == null
        ? SettingsScaffold(title: widget.title, actions: actions, body: body)
        : AppFeaturePage(
            title: widget.title,
            code: 'AI / PROMPT',
            actions: actions,
            child: body,
          );
  }
}
