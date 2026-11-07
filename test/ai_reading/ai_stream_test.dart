import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:fqapp/services/ai_reading/ai_client.dart';
import 'package:fqapp/services/ai_reading/ai_models.dart';

class _HangingClient extends http.BaseClient {
  _HangingClient(this.aborted);

  final Completer<void> aborted;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    final abortable = request as http.AbortableRequest;
    abortable.abortTrigger?.then((_) {
      if (!aborted.isCompleted) aborted.complete();
    });
    // Never returns a response. The client must abort the transport when its
    // own header timeout fires, rather than merely abandoning the future.
    return Completer<http.StreamedResponse>().future;
  }
}

class _HangingErrorClient extends http.BaseClient {
  _HangingErrorClient(this.body, this.aborted);

  final Stream<List<int>> body;
  final Completer<void> aborted;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final abortable = request as http.AbortableRequest;
    abortable.abortTrigger?.then((_) {
      if (!aborted.isCompleted) aborted.complete();
    });
    return http.StreamedResponse(body, 429);
  }
}

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
  test('header timeout aborts the underlying HTTP request', () async {
    final aborted = Completer<void>();
    final client = AiChatCompletionsClient(client: _HangingClient(aborted));
    final profile = AiProviderProfile(
      id: 'custom',
      label: 'Custom',
      baseUrl: 'https://example.com/v1',
      credentialRef: 'ref',
      outputMode: AiOutputMode.jsonObject,
      reasoningEffort: AiReasoningEffort.high,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );
    await expectLater(
      client.complete(
        profile: profile,
        apiKey: 'sk-test',
        model: 'deepseek-flash',
        messages: const [
          {'role': 'system', 'content': 'system'},
          {'role': 'user', 'content': '正文'},
        ],
        outputMode: AiOutputMode.jsonObject,
        timeout: const Duration(milliseconds: 40),
      ),
      throwsA(
        isA<AiNetworkException>().having(
          (error) => error.code,
          'code',
          'TIMEOUT',
        ),
      ),
    );
    await aborted.future.timeout(const Duration(seconds: 2));
  });

  test('non-200 body timeout is classified and aborts the request', () {
    fakeAsync((async) {
      final aborted = Completer<void>();
      final body = StreamController<List<int>>();
      final client = AiChatCompletionsClient(
        client: _HangingErrorClient(body.stream, aborted),
      );
      final profile = AiProviderProfile(
        id: 'custom',
        label: 'Custom',
        baseUrl: 'https://example.com/v1',
        credentialRef: 'ref',
        outputMode: AiOutputMode.jsonObject,
        reasoningEffort: AiReasoningEffort.high,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );
      Object? failure;
      unawaited(
        client
            .complete(
              profile: profile,
              apiKey: 'sk-test',
              model: 'deepseek-flash',
              messages: const [
                {'role': 'system', 'content': 'system'},
                {'role': 'user', 'content': '正文'},
              ],
              outputMode: AiOutputMode.jsonObject,
              timeout: const Duration(seconds: 5),
            )
            .then<void>(
              (_) {},
              onError: (Object error) {
                failure = error;
              },
            ),
      );
      async.elapse(const Duration(seconds: 31));
      async.flushMicrotasks();
      expect(failure, isA<AiNetworkException>());
      expect((failure! as AiNetworkException).code, 'TIMEOUT');
      expect(aborted.isCompleted, isTrue);
      body.close();
    });
  });

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
      messages: const [
        {'role': 'system', 'content': 'system'},
        {'role': 'user', 'content': '原章正文'},
        {'role': 'assistant', 'content': '上一轮输出'},
        {'role': 'user', 'content': '纠错说明'},
      ],
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
    final body = jsonDecode(transport.requestBody!) as Map<String, dynamic>;
    expect(body['messages'], hasLength(4));
    expect((body['messages'] as List).map((e) => (e as Map)['role']), [
      'system',
      'user',
      'assistant',
      'user',
    ]);
    expect((body['messages'] as List).last, {
      'role': 'user',
      'content': '纠错说明',
    });
  });
}
