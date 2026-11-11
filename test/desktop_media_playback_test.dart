import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

// Opt-in real libmpv decode with synthetic media and no audio device.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final source = Platform.environment['FQAPP_TEST_MEDIA'];
  test(
    'desktop libmpv decodes, pauses, seeks and releases synthetic media',
    () async {
      MediaKit.ensureInitialized();
      final player = Player(
        configuration: const PlayerConfiguration(vo: 'null'),
      );
      final errors = <String>[];
      final subscription = player.stream.error.listen(errors.add);
      try {
        await (player.platform as NativePlayer).setProperty('ao', 'null');
        await player.open(Media(source!), play: false);
        await player.stream.duration
            .firstWhere((d) => d > Duration.zero)
            .timeout(const Duration(seconds: 15));
        await player.play();
        await player.stream.position
            .firstWhere((p) => p.inMilliseconds >= 200)
            .timeout(const Duration(seconds: 15));
        await player.pause();
        expect(player.state.playing, isFalse);
        await player.seek(const Duration(milliseconds: 500));
        await player.setRate(1.25);
        await player.play();
        await player.stream.completed
            .firstWhere((done) => done)
            .timeout(const Duration(seconds: 15));
        expect(errors, isEmpty);
      } finally {
        await subscription.cancel();
        await player.dispose();
      }
    },
    skip: source == null
        ? 'Set FQAPP_TEST_MEDIA to a synthetic local/loopback clip'
        : false,
  );
}
