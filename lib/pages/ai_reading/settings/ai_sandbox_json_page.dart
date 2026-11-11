import 'package:flutter/material.dart';

import '../../../widgets/wenku/wenku_ui.dart';
import 'ai_sandbox_widgets.dart';
import 'ai_sandbox_style.dart';

/// Owned by the test console so popping this route keeps both drafts and result.
class AiSandboxJsonState {
  final original = TextEditingController();
  final response = TextEditingController();
  AiSandboxResult? result;
  void dispose() {
    original.dispose();
    response.dispose();
  }
}

class AiSandboxJsonPage extends StatefulWidget {
  const AiSandboxJsonPage({
    super.key,
    required this.state,
    required this.sample,
  });
  final AiSandboxJsonState state;
  final String sample;
  @override
  State<AiSandboxJsonPage> createState() => _AiSandboxJsonPageState();
}

class _AiSandboxJsonPageState extends State<AiSandboxJsonPage> {
  @override
  Widget build(BuildContext context) => AppFeaturePage(
    title: 'JSON 校验',
    code: 'JSON / VALIDATION',
    child: AiSandboxLayout(
      padding: featurePadding(context),
      input: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AiSandboxField(
            label: '原文',
            controller: widget.state.original,
            minLines: 4,
            action: TextButton(
              onPressed: () => widget.state.original.text = widget.sample,
              child: const Text('使用测试正文'),
            ),
          ),
          const SizedBox(height: 8),
          AiSandboxField(
            label: '模型响应',
            controller: widget.state.response,
            minLines: 8,
            monospace: true,
            action: TextButton(
              onPressed: () {
                widget.state.original.text = aiSandboxSample;
                widget.state.response.text = aiSandboxExampleResponse;
              },
              child: const Text('填入示例'),
            ),
          ),
          const SizedBox(height: 18),
          FilledButton(
            style: AiSandboxStyle(context).runButton,
            onPressed: () => setState(() {
              widget.state.result = aiSandboxValidate(
                widget.state.original.text,
                widget.state.response.text,
              );
            }),
            child: const Text('校验并预览'),
          ),
        ],
      ),
      result: AiSandboxResultView(result: widget.state.result),
    ),
  );
}
