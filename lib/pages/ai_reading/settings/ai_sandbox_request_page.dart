import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../services/ai_reading/ai_client.dart';
import '../../../services/ai_reading/ai_models.dart';
import '../../../services/ai_reading/ai_prompt.dart';
import '../../../widgets/wenku/wenku_ui.dart';
import 'ai_sandbox_style.dart';

/// This contains no credential. Both preview and coordinator use the same builders.
class AiSandboxRequest {
  AiSandboxRequest({
    required this.source,
    required this.behavior,
    required this.restore,
    required this.settings,
    required this.provider,
    required this.behaviorSource,
  });
  final String source;
  final String behavior;
  final String behaviorSource;
  final bool restore;
  final AiEffectiveSettings settings;
  final AiProviderProfile? provider;
  AiOutputMode get mode => provider?.outputMode ?? AiOutputMode.jsonObject;
  bool hasSameInputs(AiSandboxRequest other) =>
      source == other.source &&
      behavior == other.behavior &&
      behaviorSource == other.behaviorSource &&
      restore == other.restore &&
      settings.modelId == other.settings.modelId &&
      jsonEncode(provider?.toJson()) == jsonEncode(other.provider?.toJson());

  List<Map<String, String>> get messages => aiBuildChatMessages(
    behaviorPrompt: behavior,
    outputMode: mode,
    restoreCensoredWords: restore,
    userContent: source,
  );
}

class AiSandboxRequestPage extends StatelessWidget {
  const AiSandboxRequestPage({super.key, required this.request});
  final AiSandboxRequest request;
  @override
  Widget build(BuildContext context) {
    final style = AiSandboxStyle(context);
    final padding = featurePadding(context);
    final wide = MediaQuery.sizeOf(context).width >= 720;
    final texts = [
      request.messages.first['content']!,
      request.messages.last['content']!,
      const JsonEncoder.withIndent(
        '  ',
      ).convert(AiChatCompletionsClient.responseFormat(request.mode)),
    ];
    return AppFeaturePage(
      title: '请求预览',
      code: 'AI / REQUEST',
      child: DefaultTabController(
        length: 3,
        child: Padding(
          padding: padding.copyWith(
            top: padding.top - (style.classic ? 12 : 20),
            left: wide ? 28 : 16,
            right: wide ? 28 : 16,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const AiSandboxTabs(labels: ['System', 'User', '输出格式']),
              Expanded(
                child: TabBarView(
                  children: [
                    for (var index = 0; index < texts.length; index++)
                      SingleChildScrollView(
                        padding: const EdgeInsets.only(top: 18, bottom: 24),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              ['系统提示词', 'User 正文', 'response_format'][index],
                              style: TextStyle(
                                fontSize: 13,
                                color: style.palette.muted,
                              ),
                            ),
                            const SizedBox(height: 8),
                            SelectableText(
                              texts[index],
                              style: TextStyle(
                                fontSize: index == 2 ? 12 : 13,
                                height: 1.75,
                                fontFamily: index == 2 ? 'monospace' : null,
                                color: style.palette.ink,
                              ),
                            ),
                          ],
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
}
