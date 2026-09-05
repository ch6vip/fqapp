import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/pages/player_page.dart';

void main() {
  test('playback statistics reject restore and seek jumps', () {
    expect(
      countablePlaybackDelta(
        playing: true,
        previousSeconds: 0,
        currentSeconds: 300,
      ),
      0,
    );
    expect(
      countablePlaybackDelta(
        playing: true,
        previousSeconds: 300,
        currentSeconds: 302,
      ),
      2,
    );
    expect(
      countablePlaybackDelta(
        playing: true,
        previousSeconds: 302,
        currentSeconds: 120,
      ),
      0,
    );
    expect(
      countablePlaybackDelta(
        playing: false,
        previousSeconds: 120,
        currentSeconds: 122,
      ),
      0,
    );
  });
}
