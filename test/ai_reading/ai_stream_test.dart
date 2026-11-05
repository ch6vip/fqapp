import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:fqapp/services/ai_reading/ai_client.dart';
import 'package:fqapp/services/ai_reading/ai_models.dart';

class _SseClient extends http.BaseClient {
  _SseClient(this.chunks);

  final List<String> chunks;
  String? requestBody;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requestBody = (request as http.Request).body;
    return http.StreamedResponse(
      Stream<List<int>>.fromIterable(chunks.map(utf8.encode)),
      200,
      headers: const {'content-type': 'text/event-stream'},
    );
  }
}

void main() {
  test('stream reports progress and accepts output beyond 8K', () async {
    final transport = _SseClient([
      'data: {"choices":[{"delta":{"reasoning_content":"思考"},"finish_reason":null}]}\n\n',
      'data: {"choices":[{"delta":{"content":"{\\"edits\\":[]}"},"finish_reason":null}]}\n\n',
      'data: {"choices":[{"delta":{},"finish_reason":"stop"}],'
          '"usage":{"prompt_tokens":12,"completion_tokens":18000,'
          '"total_tokens":18012,"completion_tokens_details":{"reasoning_tokens":17000}}}\n\n',
      'data: [DONE]\n\n',
    ]);
    final client = AiChatCompletionsClient(client: transport);
    final progress = <AiStreamProgress>[];
    final response = await client.complete(
      profile: AiProviderProfile(
        id: 'custom',
        label: 'Custom',
        baseUrl: 'https://example.com/v1',
        credentialRef: 'ref',
        outputMode: AiOutputMode.jsonObject,
        reasoningEffort: AiReasoningEffort.high,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      ),
      apiKey: 'sk-test',
      model: 'deepseek-flash',
      systemPrompt: 'system',
      userText: 'user',
      outputMode: AiOutputMode.jsonObject,
      timeout: const Duration(seconds: 5),
      stream: true,
      onProgress: progress.add,
    );
    expect(response.content, '{"edits":[]}');
    expect(response.usage.completionTokens, 18000);
    expect(progress, isNotEmpty);
    expect(progress.last.exact, isTrue);
    expect(progress.last.estimatedTokens, 18000);
    expect(transport.requestBody, isNot(contains('"max_tokens"')));
    expect(transport.requestBody, contains('"stream":true'));
  });
}
