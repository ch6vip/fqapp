import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'ai_models.dart';
import 'ai_prompt.dart';

class AiNetworkException implements Exception {
  const AiNetworkException(
    this.code,
    this.message, {
    this.statusCode,
    this.retryable = false,
    this.retryAfter,
    this.usage,
  });

  final String code;
  final String message;
  final int? statusCode;
  final bool retryable;
  final Duration? retryAfter;
  final AiUsage? usage;

  @override
  String toString() => message;
}

class AiProviderResponse {
  const AiProviderResponse({
    required this.content,
    required this.usage,
    required this.finishReason,
    required this.latency,
    this.rawResponseBytes = 0,
  });

  final String content;
  final AiUsage usage;
  final String? finishReason;
  final Duration latency;
  final int rawResponseBytes;
}

class AiChatCompletionsClient {
  AiChatCompletionsClient({http.Client? client})
    : _client = client ?? http.Client();

  final http.Client _client;

  static Uri endpoint(String baseUrl) {
    var value = baseUrl.trim();
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    if (value.endsWith('/chat/completions')) return Uri.parse(value);
    if (value.endsWith('/v1')) return Uri.parse('$value/chat/completions');
    return Uri.parse('$value/chat/completions');
  }

  static void validateBaseUrl(String baseUrl, {bool allowLocalhost = false}) {
    final uri = Uri.tryParse(baseUrl.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw const AiNetworkException('INVALID_BASE_URL', 'Base URL 无效');
    }
    if (uri.scheme == 'https') return;
    final local =
        uri.host == 'localhost' || uri.host == '127.0.0.1' || uri.host == '::1';
    if (uri.scheme == 'http' && allowLocalhost && local) return;
    throw const AiNetworkException(
      'INSECURE_BASE_URL',
      '仅允许 HTTPS；本机 localhost 调试地址需要显式开启',
    );
  }

  /// DeepSeek uses a `thinking` object; other OpenAI-compatible providers take
  /// `reasoning_effort` directly. `auto` sends nothing so existing providers
  /// keep their server defaults.
  static Map<String, dynamic> _reasoningBody(
    AiProviderProfile profile,
    AiReasoningEffort effort,
  ) {
    if (effort == AiReasoningEffort.auto) return const {};
    if (profile.isDeepSeek) {
      if (effort == AiReasoningEffort.off) {
        return const {
          'thinking': {'type': 'disabled'},
        };
      }
      return {
        'thinking': const {'type': 'enabled'},
        'reasoning_effort': effort.wire,
      };
    }
    return {'reasoning_effort': effort.wire};
  }

  Future<AiProviderResponse> complete({
    required AiProviderProfile profile,
    required String apiKey,
    required String model,
    required List<Map<String, String>> messages,
    required AiOutputMode outputMode,
    required Duration timeout,
    bool stream = false,
    int attempt = 1,
    void Function(AiStreamProgress progress)? onProgress,
    bool jsonResponse = true,
    Future<void>? abortTrigger,
  }) async {
    validateBaseUrl(profile.baseUrl);
    final trimmedApiKey = apiKey.trim();
    if (trimmedApiKey.isEmpty) {
      throw const AiNetworkException('MISSING_KEY', '还没有填写 API Key');
    }
    // Keep credentials request-local, including while concurrent streams run.
    // Redact the raw value first so surrounding whitespace cannot hide a key.
    String redact(String text) => text
        .replaceAll(apiKey, '[REDACTED]')
        .replaceAll(trimmedApiKey, '[REDACTED]');
    if (model.trim().isEmpty) {
      throw const AiNetworkException('MISSING_MODEL', '还没有选择模型');
    }
    final uri = endpoint(profile.baseUrl);
    final body = <String, dynamic>{
      'model': model,
      'messages': messages,
      'stream': stream,
      if (stream) 'stream_options': const {'include_usage': true},
      'temperature': profile.temperature,
      ..._reasoningBody(profile, profile.reasoningEffort),
      if (jsonResponse)
        'response_format': switch (outputMode) {
          AiOutputMode.jsonObject => {'type': 'json_object'},
          AiOutputMode.jsonSchema => {
            'type': 'json_schema',
            'json_schema': {
              'name': 'ai_edits_v1',
              'strict': true,
              'schema': aiJsonSchemaProjection(),
            },
          },
        },
    };
    debugPrint(
      redact(
        '[AI] request model=$model effort=${profile.reasoningEffort.name} '
        'reasoning=${_reasoningBody(profile, profile.reasoningEffort)} ',
      ),
    );
    final started = DateTime.now();
    // A timeout must abort the transport, not merely stop awaiting it.
    // Keep a local trigger so both the caller's cancel signal and our own
    // header/body/idle timeouts reach http.AbortableRequest.
    final localAbort = Completer<void>();
    final effectiveAbort = abortTrigger == null
        ? localAbort.future
        : Future.any([abortTrigger, localAbort.future]);
    http.StreamedResponse streamed;
    try {
      final http.AbortableRequest request = http.AbortableRequest(
        'POST',
        uri,
        abortTrigger: effectiveAbort,
      );
      request
        ..followRedirects = false
        ..headers.addAll({
          'Authorization': 'Bearer $trimmedApiKey',
          'Content-Type': 'application/json',
          'Accept': stream ? 'text/event-stream' : 'application/json',
        })
        ..body = jsonEncode(body);
      streamed = await _client.send(request).timeout(timeout);
    } on TimeoutException {
      if (!localAbort.isCompleted) localAbort.complete();
      throw const AiNetworkException(
        'TIMEOUT',
        '请求超时。请求可能已经到达服务商，未自动重发',
        retryable: false,
      );
    } on http.RequestAbortedException {
      throw const AiNetworkException(
        'REQUEST_ABORTED',
        '请求已停止。请求可能已经到达服务商，未自动重发',
        retryable: false,
      );
    } on http.ClientException catch (error) {
      throw AiNetworkException(
        'NETWORK_ERROR',
        redact('网络请求失败：${error.message}'),
        retryable: true,
      );
    } catch (error) {
      throw AiNetworkException(
        'NETWORK_ERROR',
        redact('网络请求失败：$error'),
        retryable: true,
      );
    }
    if (stream) {
      return _consumeStream(
        streamed: streamed,
        started: started,
        model: model,
        attempt: attempt,
        onProgress: onProgress,
        localAbort: localAbort,
        redact: redact,
      );
    }
    http.Response response;
    try {
      response = await http.Response.fromStream(streamed).timeout(timeout);
    } on TimeoutException {
      if (!localAbort.isCompleted) localAbort.complete();
      throw const AiNetworkException(
        'TIMEOUT',
        '请求超时。请求可能已经到达服务商，未自动重发',
        retryable: false,
      );
    } on http.RequestAbortedException {
      throw const AiNetworkException(
        'REQUEST_ABORTED',
        '请求已停止。请求可能已经到达服务商，未自动重发',
        retryable: false,
      );
    } on http.ClientException catch (error) {
      throw AiNetworkException(
        'NETWORK_ERROR',
        redact('网络请求失败：${error.message}'),
        retryable: true,
      );
    } catch (error) {
      throw AiNetworkException(
        'NETWORK_ERROR',
        redact('网络请求失败：$error'),
        retryable: true,
      );
    }
    final latency = DateTime.now().difference(started);
    final text = utf8.decode(response.bodyBytes, allowMalformed: true);
    if (response.statusCode >= 300 && response.statusCode < 400) {
      throw const AiNetworkException(
        'REDIRECT_BLOCKED',
        '服务商返回重定向，已阻止携带凭据跟随',
        retryable: false,
      );
    }
    if (response.statusCode != 200) {
      final retryAfter = _retryAfter(response.headers['retry-after']);
      final detail = _errorMessage(text, redact);
      throw AiNetworkException(
        _statusCode(response.statusCode),
        detail,
        statusCode: response.statusCode,
        retryable:
            response.statusCode == 408 ||
            response.statusCode == 429 ||
            response.statusCode >= 500,
        retryAfter: retryAfter,
      );
    }
    dynamic raw;
    try {
      raw = jsonDecode(text);
    } on FormatException {
      throw const AiNetworkException(
        'API_ERROR',
        '服务商返回了非 JSON 响应',
        retryable: false,
      );
    }
    final map = _map(raw);
    if (map == null) {
      throw const AiNetworkException('API_ERROR', '服务商响应结构无效');
    }
    final choices = map['choices'];
    if (choices is! List || choices.isEmpty) {
      throw const AiNetworkException('RESPONSE_EMPTY', '服务商没有返回 choices');
    }
    final first = _map(choices.first);
    final message = _map(first?['message']);
    final finishReason = first?['finish_reason'] is String
        ? first!['finish_reason'] as String
        : null;
    final refusal = message?['refusal'];
    if (refusal is String && refusal.trim().isNotEmpty) {
      throw AiNetworkException('REFUSAL', redact('模型拒绝了本次请求：$refusal'));
    }
    final content = message?['content'];
    final usage = _usage(map['usage']);
    debugPrint(
      redact(
        '[AI] response finish=$finishReason model=$model '
        'len=${content is String ? content.length : -1} '
        'usage=${usage.promptTokens}/${usage.completionTokens}/${usage.totalTokens} '
        'reasoning=${usage.reasoningTokens}',
      ),
    );
    if (content is! String || content.trim().isEmpty) {
      throw AiNetworkException(
        'RESPONSE_EMPTY',
        finishReason == 'length' ? '模型输出被长度限制截断' : '模型返回了空内容',
        usage: usage,
      );
    }
    if (finishReason == 'length') {
      throw AiNetworkException(
        'FINISH_REASON_LENGTH',
        '模型输出被长度限制截断',
        usage: usage,
      );
    }
    if (finishReason == 'content_filter') {
      throw const AiNetworkException(
        'FINISH_REASON_CONTENT_FILTER',
        '模型输出被内容过滤',
      );
    }
    return AiProviderResponse(
      content: content,
      usage: usage,
      finishReason: finishReason,
      latency: latency,
      rawResponseBytes: response.bodyBytes.length,
    );
  }

  Future<AiProviderResponse> _consumeStream({
    required http.StreamedResponse streamed,
    required DateTime started,
    required String model,
    required int attempt,
    required void Function(AiStreamProgress progress)? onProgress,
    required Completer<void> localAbort,
    required String Function(String) redact,
  }) async {
    if (streamed.statusCode >= 300 && streamed.statusCode < 400) {
      throw const AiNetworkException(
        'REDIRECT_BLOCKED',
        '服务商返回重定向，已阻止携带凭据跟随',
        retryable: false,
      );
    }
    if (streamed.statusCode != 200) {
      String text;
      try {
        text = await utf8.decoder
            .bind(streamed.stream)
            .join()
            .timeout(const Duration(seconds: 30));
      } on TimeoutException {
        if (!localAbort.isCompleted) localAbort.complete();
        throw const AiNetworkException(
          'TIMEOUT',
          '读取错误响应超时。请求可能已经到达服务商，未自动重发',
          retryable: false,
        );
      } on http.RequestAbortedException {
        throw const AiNetworkException(
          'REQUEST_ABORTED',
          '请求已停止。请求可能已经到达服务商，未自动重发',
          retryable: false,
        );
      } on http.ClientException catch (error) {
        throw AiNetworkException(
          'NETWORK_ERROR',
          redact('网络请求失败：${error.message}'),
          retryable: true,
        );
      } catch (error) {
        throw AiNetworkException(
          'NETWORK_ERROR',
          redact('网络请求失败：$error'),
          retryable: true,
        );
      }
      throw AiNetworkException(
        _statusCode(streamed.statusCode),
        _errorMessage(text, redact),
        statusCode: streamed.statusCode,
        retryable:
            streamed.statusCode == 408 ||
            streamed.statusCode == 429 ||
            streamed.statusCode >= 500,
        retryAfter: _retryAfter(streamed.headers['retry-after']),
      );
    }

    final content = StringBuffer();
    final reasoning = StringBuffer();
    var usage = const AiUsage();
    String? finishReason;
    var lastEmit = DateTime.fromMillisecondsSinceEpoch(0);
    var lastBytes = 0;

    void emit({bool force = false}) {
      final now = DateTime.now();
      if (!force &&
          now.difference(lastEmit) < const Duration(milliseconds: 80)) {
        return;
      }
      lastEmit = now;
      final estimated = _estimateStreamTokens(
        reasoning.toString(),
        content.toString(),
      );
      final exact = usage.completionTokens != null;
      onProgress?.call(
        AiStreamProgress(
          reasoningChars: reasoning.length,
          contentChars: content.length,
          estimatedTokens: exact ? usage.completionTokens! : estimated,
          attempt: attempt,
          exact: exact,
        ),
      );
    }

    try {
      final lines = streamed.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .timeout(const Duration(seconds: 60));
      await for (final line in lines) {
        if (!line.startsWith('data:')) continue;
        final data = line.substring(5).trim();
        if (data.isEmpty) continue;
        if (data == '[DONE]') break;
        final map = _map(jsonDecode(data));
        if (map == null) continue;
        if (map['error'] != null) {
          throw AiNetworkException('API_ERROR', _errorMessage(data, redact));
        }
        final rawUsage = map['usage'];
        if (rawUsage != null) usage = _usage(rawUsage);
        final choices = map['choices'];
        if (choices is List) {
          for (final rawChoice in choices) {
            final choice = _map(rawChoice);
            if (choice == null) continue;
            final delta = _map(choice['delta']);
            final reasoningDelta =
                delta?['reasoning_content'] ?? delta?['reasoning'];
            if (reasoningDelta is String && reasoningDelta.isNotEmpty) {
              reasoning.write(reasoningDelta);
            }
            final contentDelta = delta?['content'];
            if (contentDelta is String && contentDelta.isNotEmpty) {
              content.write(contentDelta);
            }
            final finish = choice['finish_reason'];
            if (finish is String && finish.isNotEmpty) finishReason = finish;
          }
        }
        final bytes = content.length + reasoning.length;
        if (bytes != lastBytes) {
          lastBytes = bytes;
          emit();
        }
      }
    } on TimeoutException {
      if (!localAbort.isCompleted) localAbort.complete();
      throw const AiNetworkException(
        'STREAM_TIMEOUT',
        '输出中断：60 秒没有收到新内容。请求可能已经到达服务商，未自动重发',
        retryable: false,
      );
    } on http.RequestAbortedException {
      throw const AiNetworkException(
        'REQUEST_ABORTED',
        '请求已停止。请求可能已经到达服务商，未自动重发',
        retryable: false,
      );
    } on http.ClientException catch (error) {
      throw AiNetworkException(
        'NETWORK_ERROR',
        redact('网络请求失败：${error.message}'),
        retryable: true,
      );
    } on AiNetworkException catch (error) {
      throw AiNetworkException(
        error.code,
        redact(error.message),
        statusCode: error.statusCode,
        retryable: error.retryable,
        retryAfter: error.retryAfter,
        usage: error.usage,
      );
    } catch (error) {
      throw AiNetworkException(
        'NETWORK_ERROR',
        redact('网络请求失败：$error'),
        retryable: true,
      );
    }

    emit(force: true);
    final text = content.toString();
    debugPrint(
      redact(
        '[AI] stream response finish=$finishReason model=$model '
        'len=${text.length} usage=${usage.promptTokens}/${usage.completionTokens}/'
        '${usage.totalTokens} reasoning=${usage.reasoningTokens}',
      ),
    );
    if (text.trim().isEmpty) {
      throw AiNetworkException(
        'RESPONSE_EMPTY',
        finishReason == 'length' ? '模型输出被长度限制截断' : '模型返回了空内容',
        usage: usage,
      );
    }
    if (finishReason == 'length') {
      throw AiNetworkException(
        'FINISH_REASON_LENGTH',
        '模型输出被长度限制截断',
        usage: usage,
      );
    }
    if (finishReason == 'content_filter') {
      throw const AiNetworkException(
        'FINISH_REASON_CONTENT_FILTER',
        '模型输出被内容过滤',
      );
    }
    return AiProviderResponse(
      content: text,
      usage: usage,
      finishReason: finishReason,
      latency: DateTime.now().difference(started),
    );
  }

  static int _estimateStreamTokens(String reasoning, String content) {
    var units = 0.0;
    for (final rune in '$reasoning$content'.runes) {
      final cjk =
          (rune >= 0x4E00 && rune <= 0x9FFF) ||
          (rune >= 0x3040 && rune <= 0x30FF) ||
          (rune >= 0xAC00 && rune <= 0xD7AF);
      units += cjk ? 1 : 0.25;
    }
    return units.ceil();
  }

  Future<AiModelCapability> probe({
    required AiProviderProfile profile,
    required String apiKey,
    required String model,
    required AiOutputMode outputMode,
    required Duration timeout,
    void Function(AiUsage usage, String? errorCode)? onUsage,
    Future<void>? abortTrigger,
  }) async {
    final key = AiSettingsCapabilityKey.of(
      providerId: profile.id,
      baseUrl: profile.baseUrl,
      modelId: model,
      mode: outputMode,
    );
    try {
      final response = await complete(
        profile: profile,
        apiKey: apiKey,
        model: model,
        messages: [
          {
            'role': 'system',
            'content': outputMode == AiOutputMode.jsonObject
                ? '只输出 json。$kAiJsonObjectProtocol'
                : '只输出符合给定 schema 的 JSON。',
          },
          {'role': 'user', 'content': '这是连接测试。请返回 {"edits":[]}。'},
        ],
        outputMode: outputMode,
        timeout: timeout,
        abortTrigger: abortTrigger,
      );
      onUsage?.call(response.usage, null);
      return AiModelCapability(
        key: key,
        providerId: profile.id,
        endpoint: endpoint(profile.baseUrl).toString(),
        apiFamily: 'chat.completions',
        modelId: model,
        outputMode: outputMode,
        schemaStrict: outputMode == AiOutputMode.jsonSchema,
        schemaProjectionHash: aiSchemaProjectionHash(),
        verifiedAt: DateTime.now(),
        ok: true,
      );
    } on AiNetworkException catch (error) {
      onUsage?.call(error.usage ?? const AiUsage(), error.code);
      if (error.code == 'REQUEST_ABORTED') rethrow;
      return AiModelCapability(
        key: key,
        providerId: profile.id,
        endpoint: endpoint(profile.baseUrl).toString(),
        apiFamily: 'chat.completions',
        modelId: model,
        outputMode: outputMode,
        schemaStrict: false,
        schemaProjectionHash: aiSchemaProjectionHash(),
        verifiedAt: DateTime.now(),
        ok: false,
        detail: error.message,
      );
    }
  }

  static AiUsage _usage(Object? raw) {
    final map = _map(raw) ?? const {};
    final prompt = _int(map['prompt_tokens']);
    final completion = _int(map['completion_tokens']);
    final total = _int(map['total_tokens']);
    final promptDetails = _map(map['prompt_tokens_details']);
    final completionDetails = _map(map['completion_tokens_details']);
    final cached =
        _int(promptDetails?['cached_tokens']) ??
        _int(map['prompt_cache_hit_tokens']);
    final reasoning = _int(completionDetails?['reasoning_tokens']);
    final any =
        prompt != null ||
        completion != null ||
        total != null ||
        cached != null ||
        reasoning != null;
    final status = !any
        ? AiUsageStatus.unknown
        : prompt != null && (completion != null || total != null)
        ? AiUsageStatus.known
        : AiUsageStatus.partial;
    return AiUsage(
      promptTokens: prompt,
      completionTokens: completion,
      totalTokens: total,
      cachedTokens: cached,
      reasoningTokens: reasoning,
      status: status,
    );
  }

  static Duration? _retryAfter(String? value) {
    if (value == null) return null;
    final seconds = int.tryParse(value.trim());
    if (seconds != null && seconds > 0) return Duration(seconds: seconds);
    final date = DateTime.tryParse(value);
    if (date != null) {
      final delta = date.difference(DateTime.now());
      if (delta > Duration.zero) return delta;
    }
    return null;
  }

  static String _errorMessage(String text, String Function(String) redact) {
    try {
      final raw = jsonDecode(text);
      final map = _map(raw);
      final error = _map(map?['error']);
      final message = error?['message'] ?? map?['message'];
      if (message is String && message.trim().isNotEmpty) {
        // Redact before truncation, including keys crossing the cutoff.
        final safeMessage = redact(message);
        return safeMessage.length > 300
            ? safeMessage.substring(0, 300)
            : safeMessage;
      }
    } catch (_) {}
    return text.trim().isEmpty ? '服务商请求失败' : '服务商请求失败（${text.length} 字节）';
  }

  static String _statusCode(int status) => switch (status) {
    401 || 403 => 'AUTH_ERROR',
    404 => 'MODEL_OR_ENDPOINT_NOT_FOUND',
    408 => 'TIMEOUT',
    429 => 'RATE_LIMITED',
    >= 500 => 'SERVER_ERROR',
    400 || 422 => 'REQUEST_REJECTED',
    _ => 'API_ERROR',
  };

  static Map<String, dynamic>? _map(Object? value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return value.map((key, value) => MapEntry('$key', value));
    return null;
  }

  static int? _int(Object? value) => switch (value) {
    int v => v,
    num v when v.isFinite => v.toInt(),
    _ => null,
  };
}

/// Small helper kept here so the client and the settings store build the same
/// capability key without importing each other's private state.
class AiSettingsCapabilityKey {
  const AiSettingsCapabilityKey._();
  static String of({
    required String providerId,
    required String baseUrl,
    required String modelId,
    required AiOutputMode mode,
  }) {
    final endpoint = AiChatCompletionsClient.endpoint(baseUrl).toString();
    return jsonEncode([
      providerId,
      endpoint,
      'chat.completions',
      modelId,
      mode.wire,
      aiSchemaProjectionHash(),
    ]);
  }
}
