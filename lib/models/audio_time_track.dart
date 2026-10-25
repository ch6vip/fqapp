/// The 听书 → 正文 mapping that makes listen-along highlighting possible.
///
/// Mirrors the official client (`AudioSyncReaderModel` /
/// `ChapterAudioSyncReaderModel` in `com.dragon.read.component.audio.data
/// .audiosync`). The backend answers `/reading/reader/audio/timepoint/` with
/// paragraph ranges that are already aligned to the audio.
///
/// Shape measured on the live upstream (2026-10, `req_type=3`):
///
/// ```json
/// { "code": 0, "para_match_data": {
///     "audio_para_match_data": { "<audio item id>": [ point, ... ] },
///     "item_ids":              { "<audio item id>": { "0": <text item id> } },
///     "text_para_match_data":  null } }
/// ```
///
/// Each point pairs an audio start offset (`start_time`, ms) with a text range
/// as **paragraph index plus character offset inside that paragraph**.
///
/// The offsets count the *original* chapter text, punctuation included. That
/// is verified against the live timeline: the de-punctuated `speech_text` of a
/// paragraph is consistently shorter than `end_para_off` by one character per
/// sentence. So a highlight must be resolved against the same body text the
/// reader renders, not against the spoken text.
library;

/// One point: an audio start offset and the text range spoken from it.
class AudioSyncPoint {
  const AudioSyncPoint({
    required this.startTime,
    required this.startPara,
    required this.startParaOff,
    required this.endPara,
    required this.endParaOff,
    this.isTitle = false,
    this.audioItemId = '',
    this.novelItemId = '',
    this.startElementIndex,
    this.startElementOffset,
  });

  /// Audio start of this range. Milliseconds, matching the player position.
  final int startTime;

  /// Text range as (paragraph id, offset inside that paragraph).
  ///
  /// [startPara] is the upstream `<p idx="N">` id, not a display ordinal.
  final int startPara;
  final int startParaOff;
  final int endPara;
  final int endParaOff;

  /// `positionV2` element coordinates, when the response carried them.
  ///
  /// They address the same position as [startPara]/[startParaOff] but one level
  /// deeper: the index of the inline `<blk>` inside the paragraph and the
  /// character offset inside that element. Null when absent — the official
  /// client then falls back to the paragraph-level pair, which every point
  /// carries as well.
  final int? startElementIndex;
  final int? startElementOffset;

  /// Whether `positionV2` can be used (official `isNewCoordinate()` minus the
  /// all-zero case that official `isEmptyNewCoordinate()` also rejects).
  bool get hasElementCoordinate {
    final index = startElementIndex;
    final offset = startElementOffset;
    if (index == null || offset == null) return false;
    if (index < 0 || offset < 0) return false;
    // The upstream's all-zero guard would drop paragraph 0 / offset 0, which is
    // a real position; only reject it when the paragraph is also 0.
    return !(startPara == 0 && index == 0 && offset == 0);
  }

  /// The point covers the chapter title rather than body text.
  final bool isTitle;

  final String audioItemId;
  final String novelItemId;

  /// Paragraph ids at or above this are title rows (official `startPara <
  /// 10000 ? PARAGRAPH : TITLE`).
  static const int _titleParaBase = 10000;

  /// Whether the point addresses body text (rather than the title row).
  bool get isBody => !isTitle && startPara < _titleParaBase;

  static int _int(Map raw, String key, [int fallback = -1]) {
    final value = raw[key];
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? fallback;
    return fallback;
  }

  /// Parses one point. Returns null when it cannot drive a highlight.
  static AudioSyncPoint? fromPayload(dynamic raw, {String audioItemId = ''}) {
    if (raw is! Map) return null;
    final startTime = _int(raw, 'start_time');
    final startPara = _int(raw, 'start_para');
    final endPara = _int(raw, 'end_para');
    // Paragraph 0 is a real paragraph (the upstream numbers body paragraphs
    // from zero), so absence is signalled by the -1 default, not by falsiness.
    if (startTime < 0) return null;
    if (startPara < 0 && endPara < 0) return null;

    return AudioSyncPoint(
      startTime: startTime,
      startPara: startPara < 0 ? 0 : startPara,
      startParaOff: _int(raw, 'start_para_off', 0),
      endPara: endPara < 0 ? startPara : endPara,
      endParaOff: _int(raw, 'end_para_off', 0),
      isTitle: raw['is_title'] == true,
      audioItemId: audioItemId,
      novelItemId: '${raw['item_id'] ?? ''}',
      startElementIndex: _elementCoord(raw, 'start_element_index'),
      startElementOffset: _elementCoord(raw, 'start_element_offset'),
    );
  }

  /// Reads one `positionV2` field. The response spells the object both
  /// `positionV2` and `position_info_v2` depending on the endpoint, so both are
  /// accepted; a missing object yields null rather than a zero.
  static int? _elementCoord(Map raw, String key) {
    final v2 = raw['positionV2'] ?? raw['position_info_v2'];
    if (v2 is! Map) return null;
    final value = v2[key];
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  Duration get start => Duration(milliseconds: startTime);
}

/// All points for one chapter, sorted by start time.
class AudioTimeTrack {
  const AudioTimeTrack(this.points, {this.textItemId = ''});

  static const empty = AudioTimeTrack([]);

  final List<AudioSyncPoint> points;

  /// The 正文章节 id these offsets address (`item_ids[audio][0]`).
  ///
  /// The timeline is keyed by the *audio* chapter id while the ranges point at
  /// the *text* chapter; a highlight must be resolved against the latter.
  final String textItemId;

  bool get isEmpty => points.isEmpty;
  bool get isNotEmpty => points.isNotEmpty;

  /// Index of the point covering [position], or `-1` before the first one.
  ///
  /// Points are sorted by `startTime`, so this is a binary search: the reader
  /// calls it on every position tick (5 Hz) and must stay allocation-free.
  int indexAt(Duration position) {
    if (points.isEmpty) return -1;
    final target = position.inMilliseconds;
    if (target < points.first.startTime) return -1;
    var low = 0;
    var high = points.length - 1;
    var found = -1;
    while (low <= high) {
      final mid = (low + high) >> 1;
      if (points[mid].startTime <= target) {
        found = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return found;
  }

  AudioSyncPoint? pointAt(Duration position) {
    final index = indexAt(position);
    return index < 0 ? null : points[index];
  }

  /// Parses the `para_match_data` envelope.
  ///
  /// [textItemId] is optional: when the caller already knows which chapter it
  /// is rendering, the envelope's own mapping is only used as a fallback.
  /// Failures and an absent list both yield [empty] — the timeline is
  /// decoration, and a book without one must keep playing.
  static AudioTimeTrack fromPayload(
    dynamic payload, {
    String audioItemId = '',
  }) {
    if (payload is! Map) return empty;
    // The envelope nests the ranges under `para_match_data`; also accept the
    // flat `data.time_points` shape so a config change cannot silently blank
    // the highlight.
    final match = payload['para_match_data'] ?? payload['data'];
    if (match is! Map) return empty;

    final byAudio = match['audio_para_match_data'];
    final itemIds = match['item_ids'];

    final List rawPoints;
    final audioKey = audioItemId.isNotEmpty ? audioItemId : null;
    if (byAudio is Map && byAudio.isNotEmpty) {
      final key = (audioKey != null && byAudio.containsKey(audioKey))
          ? audioKey
          : '${byAudio.keys.first}';
      final list = byAudio[key];
      if (list is! List) return empty;
      rawPoints = list;
      audioItemId = key;
    } else {
      final flat = match['time_points'] ?? match['timePoints'];
      if (flat is! List) return empty;
      rawPoints = flat;
    }

    final parsed = <AudioSyncPoint>[];
    for (final raw in rawPoints) {
      final point = AudioSyncPoint.fromPayload(raw, audioItemId: audioItemId);
      if (point != null) parsed.add(point);
    }
    if (parsed.isEmpty) return empty;
    parsed.sort((a, b) => a.startTime.compareTo(b.startTime));

    var textItemId = '';
    if (itemIds is Map) {
      final perAudio = itemIds[audioItemId];
      if (perAudio is Map && perAudio.isNotEmpty) {
        textItemId = '${perAudio[perAudio.keys.first] ?? ''}';
      }
    }

    return AudioTimeTrack(List.unmodifiable(parsed), textItemId: textItemId);
  }
}
