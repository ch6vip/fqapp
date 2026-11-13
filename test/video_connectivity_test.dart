import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/connectivity_status.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.linux,
  ]) {
    test(
      '${platform.name} does not block foreground playback on an offline adapter report',
      () async {
        debugDefaultTargetPlatformOverride = platform;
        var checked = false;
        final offline = await videoNetworkIsOffline(
          probe: () async {
            checked = true;
            return (online: false, metered: false);
          },
        );
        expect(offline, isFalse);
        expect(checked, isFalse);
      },
    );
  }

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    test(
      '${platform.name} retains local-only playback when disconnected',
      () async {
        debugDefaultTargetPlatformOverride = platform;
        expect(
          await videoNetworkIsOffline(
            probe: () async => (online: false, metered: false),
          ),
          isTrue,
        );
        expect(
          await videoNetworkIsOffline(
            probe: () async => (online: true, metered: true),
          ),
          isFalse,
        );
      },
    );
  }
}
