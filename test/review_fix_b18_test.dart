import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Pins the B18 WebView legacy-page fixes at the asset source level. These
/// pages execute inside a WebView, so a Flutter widget test cannot run their
/// JavaScript; asserting the served assets keeps the corrected contracts
/// (image-array ingestion, playable-audio fallback and tab-typed search with
/// real series ids) from silently regressing.
void main() {
  String asset(String name) => File('assets/web/$name').readAsStringSync();

  test('comic reader accepts the backend images array before HTML parsing', () {
    final comic = asset('comic.html');
    expect(comic, contains('Array.isArray(rawImages)'));
    expect(comic, contains('rawImages ?? payload.data?.content'));
    expect(comic, isNot(contains('String(payload.data?.images || "")')));
  });

  test('listen page falls back to the audio playback endpoint for a URL', () {
    final listen = asset('listen.html');
    expect(listen, contains('/api/v1/audio/play'));
    expect(listen, contains('fetchPlaybackURL(current.id, requestedToneId)'));
    expect(listen, contains('video_model_datas'));
  });

  test(
    'index search requests each tab type and uses short-drama series ids',
    () {
      final index = asset('index.html');
      expect(index, contains('searchTabTypes'));
      expect(index, contains('tab_type='));
      expect(index, contains('video.series_id'));
      expect(index, isNot(contains('id: item.book_id')));
    },
  );
}
