import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/fair_memory.dart';

/// 1x1 透明 PNG，给 TRIM 测试用的真实解码图。
final _transparentPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

/// 小米澎湃 OS 公平运行内存：原生侧经 `fqapp/fair_memory` 通道把 TRIM/KILL
/// 广播转发给 Dart，Dart 返回是否处理成功。测试用平台消息模拟原生侧调用。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final service = FairMemoryService.instance;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const codec = StandardMethodCodec();

  /// 模拟原生侧一次 `onMemoryWarning` 调用，返回 Dart 侧的返回值。
  Future<dynamic> sendMemoryWarning(Object? arguments) async {
    ByteData? reply;
    await messenger.handlePlatformMessage(
      'fqapp/fair_memory',
      codec.encodeMethodCall(MethodCall('onMemoryWarning', arguments)),
      (ByteData? response) {
        reply = response;
      },
    );
    return codec.decodeEnvelope(reply!);
  }

  tearDown(() {
    service.clearFlushHandlersForTest();
    service.setFlushTimeoutForTest(const Duration(seconds: 2));
  });

  testWidgets('TRIM 清空内存图片缓存', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: Image.memory(_transparentPng)),
    );
    await tester.pump();
    final cache = PaintingBinding.instance.imageCache;
    expect(cache.liveImageCount, greaterThan(0));

    final handled = await sendMemoryWarning(<String, Object>{
      'kind': 'trim',
      'notifyType': 1000,
      'notifyId': 1,
    });

    expect(handled, isTrue);
    expect(cache.currentSizeBytes, 0);
    expect(cache.liveImageCount, 0);
  });

  test('KILL 跑完登记的刷盘回调后返回 true', () async {
    final ran = <String>[];
    service.registerFlushHandler(() async {
      ran.add('reader');
    });
    service.registerFlushHandler(() async {
      ran.add('player');
    });

    final handled = await sendMemoryWarning(<String, Object>{
      'kind': 'kill',
      'notifyType': 2000,
      'notifyId': 2,
    });

    expect(handled, isTrue);
    expect(ran, <String>['reader', 'player']);
  });

  test('KILL 无刷盘回调时直接返回 true', () async {
    final handled = await sendMemoryWarning(<String, Object>{
      'kind': 'kill',
      'notifyType': 2000,
      'notifyId': 3,
    });
    expect(handled, isTrue);
  });

  test('KILL 某个回调抛错时其他回调照常跑，返回 false', () async {
    final ran = <String>[];
    service.registerFlushHandler(() async {
      ran.add('before');
    });
    service.registerFlushHandler(() async {
      throw StateError('save failed');
    });
    service.registerFlushHandler(() async {
      ran.add('after');
    });

    final handled = await sendMemoryWarning(<String, Object>{
      'kind': 'kill',
      'notifyType': 2000,
      'notifyId': 4,
    });

    expect(handled, isFalse);
    expect(ran, <String>['before', 'after']);
  });

  test('KILL 刷盘超时返回 false', () async {
    service.setFlushTimeoutForTest(const Duration(milliseconds: 50));
    var ran = false;
    service.registerFlushHandler(() async {
      ran = true;
      await Completer<void>().future;
    });

    final handled = await sendMemoryWarning(<String, Object>{
      'kind': 'kill',
      'notifyType': 2000,
      'notifyId': 5,
    });

    expect(handled, isFalse);
    expect(ran, isTrue);
  });

  test('未知 kind / 非 Map 参数返回 false', () async {
    expect(
      await sendMemoryWarning(<String, Object>{
        'kind': 'unknown',
        'notifyType': 1000,
        'notifyId': 6,
      }),
      isFalse,
    );
    expect(await sendMemoryWarning('not-a-map'), isFalse);
  });

  test('注销后的回调不再被 KILL 调用', () async {
    var ran = false;
    final unregister = service.registerFlushHandler(() async {
      ran = true;
    });
    unregister();

    final handled = await sendMemoryWarning(<String, Object>{
      'kind': 'kill',
      'notifyType': 2000,
      'notifyId': 7,
    });

    expect(handled, isTrue);
    expect(ran, isFalse);
  });
}
