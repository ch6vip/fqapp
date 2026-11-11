import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../services/ai_reading/ai_client.dart';
import '../../../services/ai_reading/ai_models.dart';
import '../../../services/ai_reading/ai_prompt.dart';
import '../../../widgets/wenku/wenku_ui.dart';

/// This contains no credential. Both preview and coordinator use the same builders.
class AiSandboxRequest {
  AiSandboxRequest({
    required this.source,
    required this.behavior,
    required this.restore,
    required this.settings,
    required this.provider,
  });
  final String source;
  final String behavior;
  final bool restore;
  final AiEffectiveSettings settings;
  final AiProviderProfile? provider;
  AiOutputMode get mode => provider?.outputMode ?? AiOutputMode.jsonObject;
  List<Map<String, String>> get messages => aiBuildChatMessages(
    behaviorPrompt: behavior,
    outputMode: mode,
    restoreCensoredWords: restore,
    userContent: source,
  );
}

class AiSandboxRequestPage extends StatelessWidget {
  const AiSandboxRequestPage({
    super.key,
    required this.request,
    required this.captured,
  });
  final AiSandboxRequest request;
  final bool captured;
  @override
  Widget build(BuildContext context) => AppFeaturePage(
    title: '查看请求',
    code: 'AI / REQUEST',
    child: DefaultTabController(
      length: 3,
      child: Padding(
        padding: featurePadding(context),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(captured ? '本次请求快照' : '当前配置预览'),
            const SizedBox(height: 8),
            Text(
              '${request.provider?.label ?? '未选择提供商'} / ${request.settings.modelId ?? '未选择模型'}',
            ),
            const TabBar(
              isScrollable: true,
              tabs: [
                Tab(text: 'System'),
                Tab(text: 'User'),
                Tab(text: '输出格式'),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: [
                  for (final text in [
                    request.messages.first['content']!,
                    request.messages.last['content']!,
                    const JsonEncoder.withIndent('  ').convert(
                      AiChatCompletionsClient.responseFormat(request.mode),
                    ),
                  ])
                    SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: SelectableText(
                        text,
                        style: const TextStyle(fontSize: 13, height: 1.75),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
