import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/reader_device.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('fqapp/reader');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'reader brightness commands use one session and close prevents reuse',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return switch (call.method) {
          'start' => {
            'timestamp': 1789027200000,
            'battery': 67,
            'charging': true,
            'systemBrightness': 0.4,
          },
          'setBrightness' => true,
          _ => null,
        };
      });
      final device = ReaderDevice();
      final status = await device.start(followSystem: true, brightness: 0.2);
      expect(status?.battery, 67);
      expect(status?.charging, isTrue);
      expect(status?.systemBrightness, 0.4);
      expect(
        await device.setBrightness(followSystem: false, brightness: 0.25),
        isTrue,
      );
      await device.suspend();
      await device.start(followSystem: false, brightness: 0.25);
      await device.close();
      expect(calls.map((call) => call.method), [
        'start',
        'setBrightness',
        'suspend',
        'start',
        'stop',
      ]);
      expect(
        calls.map((call) => call.arguments['session']).toSet(),
        hasLength(1),
      );
      expect(calls.first.arguments['brightness'], -1.0);
      expect(calls[1].arguments['brightness'], 0.25);
      expect(await device.start(followSystem: true, brightness: 0.5), isNull);
      expect(
        await device.setBrightness(followSystem: true, brightness: 0.5),
        isFalse,
      );
      expect(calls, hasLength(5));
    },
  );

  test('a start response after close cannot reactivate the reader', () async {
    final pending = Completer<Object?>();
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return call.method == 'start' ? pending.future : null;
    });
    final device = ReaderDevice();
    final start = device.start(followSystem: false, brightness: 0.2);
    await device.close();
    pending.complete({'timestamp': 0, 'battery': 50});
    expect(await start, isNull);
    expect(calls, ['start', 'stop']);
  });

  test('a missing platform bridge does not break reader cleanup', () async {
    final device = ReaderDevice();
    expect(await device.start(followSystem: true, brightness: 0.5), isNull);
    expect(
      await device.setBrightness(followSystem: false, brightness: 0.5),
      isFalse,
    );
    await device.suspend();
    await device.close();
  });

  test(
    'unavailable battery values remain unknown instead of displaying zero',
    () {
      final status = ReaderDeviceStatus.fromMap({
        'battery': -1,
        'systemBrightness': double.nan,
      });
      expect(status.battery, isNull);
      expect(status.systemBrightness, isNull);
    },
  );

  test('font picker cancellation leaves the font unchanged', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    expect(await ReaderDevice().pickFont(), isNull);
  });
}
