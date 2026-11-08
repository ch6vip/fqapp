import 'package:flutter/material.dart';

import '../../../widgets/home/home_design.dart';
import '../../../widgets/settings/settings_widgets.dart';

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
  });

  final String title;
  final String initial;
  final String? hint;

  /// Global prompts use an empty string to mean「内置默认」. Book prompts must
  /// contain something because they are an explicit override.
  final bool allowEmpty;

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
    return SettingsScaffold(
      title: widget.title,
      actions: [TextButton(onPressed: _save, child: const Text('保存'))],
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
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
                child: Container(
                  decoration: BoxDecoration(
                    color: palette.surface,
                    borderRadius: BorderRadius.circular(
                      SettingsGroupCard.radius,
                    ),
                    border: Border.all(color: palette.line, width: 0.6),
                  ),
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
                  child: TextField(
                    controller: _controller,
                    maxLines: null,
                    expands: true,
                    textAlignVertical: TextAlignVertical.top,
                    keyboardType: TextInputType.multiline,
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      isDense: true,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 6),
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
                    '${_controller.text.length} 字符',
                    style: TextStyle(fontSize: 12, color: palette.muted),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
