import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:fqapp/services/ai_reading/ai_client.dart';
import 'package:fqapp/services/ai_reading/ai_models.dart';
import 'package:fqapp/services/ai_reading/ai_request_foreground.dart';

class _AbortingClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    throw http.RequestAbortedException(request.url);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('fqapp/ai_request');
  var platformWasOverridden = false;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    platformWasOverridden = true;
  });

  tearDown(() {
    if (platformWasOverridden) {
      debugDefaultTargetPlatformOverride = null;
      platformWasOverridden = false;
    }
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('acquire rejects a lease stopped during the native handshake', () async {
    final acquire = Completer<String?>();
    final releases = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'acquire':
              return acquire.future;
            case 'release':
              final args = call.arguments as Map?;
              releases.add(args?['leaseId'] as String? ?? '');
              return null;
          }
          return null;
        });

    final pending = AiRequestForeground.acquire();
    await Future<void>.delayed(Duration.zero);
    AiRequestForeground.debugServiceStopped();
    acquire.complete('lease-handshake');

    await expectLater(
      pending,
      throwsA(
        isA<AiNetworkException>().having(
          (error) => error.code,
          'code',
          'FOREGROUND_STOPPED',
        ),
      ),
    );
    expect(releases, ['lease-handshake']);
  });

  test(
    'probe propagates user cancellation instead of caching a failure',
    () async {
      final client = AiChatCompletionsClient(client: _AbortingClient());
      final profile = AiProviderProfile(
        id: 'magpie',
        label: 'Magpie',
        baseUrl: 'https://example.com/v1',
        credentialRef: 'ref',
        outputMode: AiOutputMode.jsonSchema,
        reasoningEffort: AiReasoningEffort.auto,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );

      await expectLater(
        client.probe(
          profile: profile,
          apiKey: 'sk-test',
          model: 'group/test',
          outputMode: AiOutputMode.jsonSchema,
          timeout: const Duration(seconds: 5),
          abortTrigger: Completer<void>().future,
        ),
        throwsA(
          isA<AiNetworkException>().having(
            (error) => error.code,
            'code',
            'REQUEST_ABORTED',
          ),
        ),
      );
    },
  );

  test('foreground status updates reach the native channel', () async {
    final updates = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'updateNotification') {
            updates.add((call.arguments as Map)['text'] as String);
          }
          return null;
        });

    await AiRequestForeground.updateNotification('正在思考…');
    await AiRequestForeground.updateNotification('正在生成修改…');
    expect(updates, ['正在思考…', '正在生成修改…']);
  });

  test(
    'notification permission is requested through the native bridge',
    () async {
      var requests = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'requestNotifications') {
              requests++;
              return true;
            }
            return null;
          });

      expect(await AiRequestForeground.ensureNotificationPermission(), isTrue);
      expect(requests, 1);
    },
  );

  test('stopping the service aborts every outstanding lease', () async {
    var next = 0;
    final releases = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'acquire':
              next++;
              return 'lease-$next';
            case 'release':
              final args = call.arguments as Map?;
              releases.add(args?['leaseId'] as String? ?? '');
              return null;
          }
          return null;
        });

    final first = await AiRequestForeground.acquire();
    final second = await AiRequestForeground.acquire();
    AiRequestForeground.debugServiceStopped();

    await expectLater(first.abortTrigger, completes);
    await expectLater(second.abortTrigger, completes);

    await first.release();
    await second.release();
    expect(releases.toSet(), {'lease-1', 'lease-2'});
  });
}
