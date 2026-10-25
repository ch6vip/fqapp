import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/audio_time_track.dart';

/// The 听书 → 正文 mapping (official `AudioTimePoint`).
///
/// Every case below is pinned to the shape measured on the live upstream
/// (`req_type=3`): ranges live under `para_match_data.audio_para_match_data`,
/// keyed by the *audio* chapter id, and `item_ids` maps that to the *text*
/// chapter. Getting either wrong silently blanks or misplaces the highlight.
void main() {
  /// One upstream point, exactly as the service returns it.
  Map<String, dynamic> point({
    required int startTime,
    required int startPara,
    required int startParaOff,
    required int endPara,
    required int endParaOff,
    int textItemId = 7257740371885556000,
  }) => {
    'start_time': startTime,
    'start_para': startPara,
    'start_para_off': startParaOff,
    'end_para': endPara,
    'end_para_off': endParaOff,
    'item_id': textItemId,
    'item_title': '第1章 大巴',
    'positionV2': {
      'start_container_index': startPara,
      'end_container_index': endPara,
    },
  };

  /// A live-shaped envelope.
  Map<String, dynamic> envelope({
    String audioId = '7256784068786785336',
    String textId = '7257740371885556000',
    required List<Map<String, dynamic>> points,
  }) => {
    'code': 0,
    'message': 'SUCCESS',
    'para_match_data': {
      'audio_para_match_data': {audioId: points},
      'item_ids': {
        audioId: {'0': int.parse(textId)},
      },
      'text_para_match_data': null,
    },
  };

  group('AudioTimeTrack.fromPayload (live shape)', () {
    test('reads ranges from para_match_data.audio_para_match_data', () {
      final track = AudioTimeTrack.fromPayload(
        envelope(
          points: [
            point(
              startTime: 0,
              startPara: 0,
              startParaOff: 0,
              endPara: 0,
              endParaOff: 27,
            ),
            point(
              startTime: 25110,
              startPara: 1,
              startParaOff: 0,
              endPara: 1,
              endParaOff: 13,
            ),
          ],
        ),
        audioItemId: '7256784068786785336',
      );

      expect(track.points, hasLength(2));
      expect(track.points.first.startTime, 0);
      expect(track.points.first.endParaOff, 27);
      expect(track.points.last.startTime, 25110);
    });

    test('exposes the text chapter id from item_ids', () {
      final track = AudioTimeTrack.fromPayload(
        envelope(
          points: [
            point(
              startTime: 0,
              startPara: 0,
              startParaOff: 0,
              endPara: 0,
              endParaOff: 5,
            ),
          ],
        ),
      );
      // The ranges address this chapter, not the audio one.
      expect(track.textItemId, '7257740371885556000');
    });

    test('sorts by start time even when the payload is unordered', () {
      final track = AudioTimeTrack.fromPayload(
        envelope(
          points: [
            point(
              startTime: 5000,
              startPara: 2,
              startParaOff: 0,
              endPara: 2,
              endParaOff: 12,
            ),
            point(
              startTime: 0,
              startPara: 1,
              startParaOff: 0,
              endPara: 1,
              endParaOff: 20,
            ),
          ],
        ),
      );
      expect(track.points.first.startTime, 0);
      expect(track.points.last.startTime, 5000);
    });

    test('junk, absence and the error envelopes all yield empty', () {
      expect(AudioTimeTrack.fromPayload(null).isEmpty, isTrue);
      expect(AudioTimeTrack.fromPayload({'code': 0}).isEmpty, isTrue);
      expect(
        AudioTimeTrack.fromPayload({
          'para_match_data': {'audio_para_match_data': null},
        }).isEmpty,
        isTrue,
      );
      // The measured failure envelopes: no usable ranges.
      expect(
        AudioTimeTrack.fromPayload({
          'code': 101049,
          'message': 'TTS_MAY_HASNT_PRODUCT',
          'data': {'time_points': null},
        }).isEmpty,
        isTrue,
      );
    });

    test('the flat data.time_points shape still parses', () {
      // Kept so a server-side shape change cannot silently blank the highlight.
      final track = AudioTimeTrack.fromPayload({
        'code': 0,
        'data': {
          'time_points': [
            point(
              startTime: 0,
              startPara: 1,
              startParaOff: 0,
              endPara: 1,
              endParaOff: 4,
            ),
          ],
        },
      });
      expect(track.points, hasLength(1));
    });
  });

  group('AudioTimeTrack.indexAt', () {
    final track = AudioTimeTrack.fromPayload(
      envelope(
        points: [
          for (var i = 0; i < 5; i++)
            point(
              startTime: i * 1000,
              startPara: i,
              startParaOff: 0,
              endPara: i,
              endParaOff: 10,
            ),
        ],
      ),
    );

    test('before the first point nothing is highlighted', () {
      expect(track.indexAt(const Duration(milliseconds: -1)), -1);
      expect(track.pointAt(const Duration(milliseconds: -1)), isNull);
    });

    test('each instant lands inside its own window', () {
      for (var i = 0; i < 5; i++) {
        final at = Duration(milliseconds: i * 1000 + 500);
        expect(track.indexAt(at), i, reason: 'inside window $i');
      }
    });

    test('a boundary belongs to the later point', () {
      // 2000ms is the start of window 2: the audio has moved on, and holding
      // the previous line would look stuck.
      expect(track.indexAt(const Duration(milliseconds: 2000)), 2);
    });

    test('past the last point keeps the last one', () {
      expect(track.indexAt(const Duration(seconds: 99)), 4);
    });

    test('empty track never returns an index', () {
      expect(AudioTimeTrack.empty.indexAt(const Duration(seconds: 3)), -1);
    });
  });

  group('AudioSyncPoint.isBody', () {
    test('paragraph 0 is real body text, not a sentinel', () {
      // Measured: the upstream numbers body paragraphs from zero.
      final first = AudioSyncPoint.fromPayload(
        point(
          startTime: 0,
          startPara: 0,
          startParaOff: 0,
          endPara: 0,
          endParaOff: 27,
        ),
      )!;
      expect(first.isBody, isTrue);
      expect(first.startPara, 0);
    });

    test('paragraph ids at or above 10000 are title rows', () {
      // Official: `startPara < 10000 ? PARAGRAPH : TITLE`.
      final high = AudioSyncPoint.fromPayload(
        point(
          startTime: 0,
          startPara: 10000,
          startParaOff: 0,
          endPara: 10000,
          endParaOff: 5,
        ),
      )!;
      expect(high.isBody, isFalse);
    });

    test('a point without a start time is rejected', () {
      final bad = AudioSyncPoint.fromPayload({
        'start_para': 1,
        'end_para': 1,
        'start_para_off': 0,
        'end_para_off': 4,
      });
      expect(bad, isNull);
    });
  });
}
