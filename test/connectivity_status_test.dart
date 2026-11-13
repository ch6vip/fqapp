import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/connectivity_status.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.fluttercommunity.plus/connectivity');

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  testWidgets('provider asynchronous failure is unknown and stays contained', (
    tester,
  ) async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (_) {
      scheduleMicrotask(() => throw StateError('system bus unavailable'));
      return Completer<Object?>().future;
    });
    final escaped = <Object>[];
    var completed = false;
    ConnectivityView? value;
    runZonedGuarded(() {
      unawaited(
        probeConnectivity().then((result) {
          completed = true;
          value = result;
        }),
      );
    }, (error, _) => escaped.add(error));
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    expect(escaped, isEmpty);
    expect(completed, isTrue);
    expect(value, isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('unresponsive provider is bounded without inventing Wi-Fi', (
    tester,
  ) async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (_) => Completer<Object?>().future,
    );
    var completed = false;
    ConnectivityView? value;
    unawaited(
      probeConnectivity().then((result) {
        completed = true;
        value = result;
      }),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    expect(completed, isTrue);
    expect(value, isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  test('reported connectivity preserves offline and metered states', () async {
    for (final sample in [
      (['none'], (online: false, metered: false)),
      (['wifi'], (online: true, metered: false)),
      (['mobile'], (online: true, metered: true)),
    ]) {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (_) async => sample.$1,
      );
      expect(await probeConnectivity(), sample.$2);
    }
    expect(foldConnectivity([ConnectivityResult.vpn]), (
      online: true,
      metered: true,
    ));
  });
}
