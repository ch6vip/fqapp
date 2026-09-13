/// Audio-side extras for the listening page: voice tones (智能朗读 / 真人讲书),
/// the spoken-subtitle track (边听边读), and related works (原著小说 / 改编短剧).
///
/// Shapes verified against live responses and against the official client's
/// own models. Two details matter and are easy to get wrong:
///
///  * `/api/v1/books/{id}/tones` uses **lowercase** JSON keys (`id`, `title`,
///    `description`, `badge`, `is_multi_tone`), unlike the PascalCase
///    `ToneInfo` RPC model.
///  * `/api/v1/chapters/{id}/timeline` only answers when `genre` and `tone_id`
///    are supplied explicitly; the backend defaults (`genre=4`, `tone_id=99`)
///    return `1301008 no available speech text`.
library;

/// A selectable reading voice.
class AudioTone {
  const AudioTone({
    required this.id,
    required this.title,
    this.description = '',
    this.badge = '',
    this.iconUrl = '',
    this.isMultiTone = false,
    this.gender = 0,
  });

  final String id;
  final String title;

  /// Short quality caption, e.g. `自然流畅` / `超自然` / `声临其境`.
  final String description;

  /// Corner chip such as `升级`; empty for most tones.
  final String badge;
  final String iconUrl;

  /// Multi-role dialogue tones (多角色对话), shown in their own group.
  final bool isMultiTone;

  /// `1` male-leaning, `2` female-leaning, `0` unspecified.
  final int gender;

  bool get isEmpty => id.isEmpty && title.isEmpty;

  static AudioTone? fromRaw(dynamic raw) {
    if (raw is! Map) return null;
    final id = _string(raw['id']);
    final title = _string(raw['title']);
    if (id.isEmpty && title.isEmpty) return null;
    return AudioTone(
      id: id,
      title: title,
      description: _string(raw['description']),
      badge: _string(raw['badge']),
      iconUrl: _string(raw['icon_url']),
      isMultiTone: raw['is_multi_tone'] == true,
      gender: _int(raw['tone_gender']),
    );
  }
}

/// Every voice the backend offers for one book.
class AudioToneSet {
  const AudioToneSet({
    this.ttsTones = const [],
    this.offlineTones = const [],
    this.narratorTones = const [],
  });

  /// 智能朗读 voices (the 多角色对话 / 成熟大叔音 family).
  final List<AudioTone> ttsTones;

  /// Downloaded/offline voices.
  final List<AudioTone> offlineTones;

  /// 真人讲书 narrators, whose `title` is already `主播：…`.
  final List<AudioTone> narratorTones;

  bool get isEmpty =>
      ttsTones.isEmpty && offlineTones.isEmpty && narratorTones.isEmpty;

  /// First tone to preselect, preferring a multi-role tone as the official page
  /// does, then the first available voice.
  AudioTone? get recommended {
    for (final tone in ttsTones) {
      if (tone.isMultiTone) return tone;
    }
    if (ttsTones.isNotEmpty) return ttsTones.first;
    if (narratorTones.isNotEmpty) return narratorTones.first;
    return null;
  }

  static AudioToneSet fromPayload(Map<String, dynamic> payload) {
    final data = _resolveData(payload);
    if (data == null) return const AudioToneSet();
    return AudioToneSet(
      ttsTones: _toneList(data['tts_tones']),
      offlineTones: _toneList(data['offline_tts_tones']),
      // 真人讲书 entries carry `abook_id` instead of `id`.
      narratorTones: _toneList(data['audio_tones'], idKey: 'abook_id'),
    );
  }
}

/// One spoken subtitle line with its start offset.
class SubtitleCue {
  const SubtitleCue({required this.startMs, required this.text});

  final int startMs;
  final String text;
}

/// The 边听边读 timeline.
///
/// Note: 字幕端点必须显式传 genre/tone_id，默认参数恒返回 1301008 — 见
/// .agents/notes/implemented/feature/2026-09-10-detail-audio-replica.md
///
/// The backend returns `data.speech_text` as plain lines of the form
/// `[3025,0]<3025,0,0>对不起`; only the leading offset and the trailing text are
/// meaningful here.
class SubtitleTrack {
  const SubtitleTrack(this.cues);

  static const empty = SubtitleTrack([]);

  final List<SubtitleCue> cues;

  bool get isEmpty => cues.isEmpty;
  bool get isNotEmpty => cues.isNotEmpty;

  /// Index of the line that should be highlighted at [position], or `-1`.
  /// Cues are sorted by start time, so this is a binary search.
  int indexAt(Duration position) {
    if (cues.isEmpty) return -1;
    final target = position.inMilliseconds;
    if (target < cues.first.startMs) return -1;
    var low = 0;
    var high = cues.length - 1;
    var found = -1;
    while (low <= high) {
      final mid = (low + high) >> 1;
      if (cues[mid].startMs <= target) {
        found = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return found;
  }

  SubtitleCue? cueAt(Duration position) {
    final index = indexAt(position);
    return index < 0 ? null : cues[index];
  }

  /// The current line and the one that follows, matching the two-line display.
  (SubtitleCue? current, SubtitleCue? next) windowAt(Duration position) {
    final index = indexAt(position);
    if (index < 0) return (null, cues.isEmpty ? null : cues.first);
    return (cues[index], index + 1 < cues.length ? cues[index + 1] : null);
  }

  static SubtitleTrack parse(dynamic speechText) {
    final raw = _string(speechText);
    if (raw.isEmpty) return empty;
    final cues = <SubtitleCue>[];
    for (final line in raw.split('\n')) {
      final match = _cuePattern.firstMatch(line.trim());
      if (match == null) continue;
      final startMs = int.tryParse(match.group(1) ?? '');
      final text = (match.group(2) ?? '').trim();
      if (startMs == null || text.isEmpty) continue;
      cues.add(SubtitleCue(startMs: startMs, text: text));
    }
    if (cues.isEmpty) return empty;
    cues.sort((a, b) => a.startMs.compareTo(b.startMs));
    return SubtitleTrack(List.unmodifiable(cues));
  }

  static SubtitleTrack fromPayload(Map<String, dynamic> payload) {
    final data = _resolveData(payload);
    if (data == null) return empty;
    return parse(data['speech_text']);
  }

  /// `[3025,0]<3025,0,0>对不起`
  static final _cuePattern = RegExp(r'^\[(\d+),\d+\]<\d+,\d+,\d+>(.*)$');
}

/// A companion work shown next to the audio player: the original novel or an
/// adaptation. Derives from `/api/v1/books/{id}/related`.
class RelatedWork {
  const RelatedWork({
    required this.kind,
    required this.id,
    required this.title,
    this.cover = '',
    this.label = '',
  });

  /// `book` for the original novel, `video` for a short-drama adaptation.
  final String kind;
  final String id;
  final String title;
  final String cover;

  /// Caption under the title (`原著小说` / `改编短剧`).
  final String label;

  bool get isEmpty => id.isEmpty && title.isEmpty;

  static List<RelatedWork> fromPayload(Map<String, dynamic> payload) {
    final data = _resolveData(payload);
    if (data == null) return const [];
    final cells = data['cell_data'];
    if (cells is! List) return const [];
    final works = <RelatedWork>[];
    for (final cell in cells) {
      if (cell is! Map) continue;
      final books = cell['book_data'];
      if (books is List) {
        for (final entry in books) {
          final work = _work(entry, kind: 'book', label: '原著小说');
          if (work != null) works.add(work);
        }
      }
      final videos = cell['video_data'];
      if (videos is List) {
        for (final entry in videos) {
          final work = _work(entry, kind: 'video', label: '改编短剧');
          if (work != null) works.add(work);
        }
      }
      if (works.isNotEmpty) break;
    }
    return List.unmodifiable(works);
  }

  static RelatedWork? _work(
    dynamic raw, {
    required String kind,
    required String label,
  }) {
    if (raw is! Map) return null;
    final title = _string(raw['book_name']).isNotEmpty
        ? _string(raw['book_name'])
        : _string(raw['title']);
    // Series entries identify themselves with `series_id`; episode results keep
    // `book_id`, so accept both.
    final id = _string(raw['book_id']).isNotEmpty
        ? _string(raw['book_id'])
        : _string(raw['series_id']);
    if (id.isEmpty && title.isEmpty) return null;
    final cover = _string(raw['thumb_url']).isNotEmpty
        ? _string(raw['thumb_url'])
        : _string(raw['cover']).isNotEmpty
        ? _string(raw['cover'])
        : _string(raw['cover_url']).isNotEmpty
        ? _string(raw['cover_url'])
        : _string(raw['poster_url']);
    return RelatedWork(
      kind: kind,
      id: id,
      title: title,
      cover: cover,
      label: label,
    );
  }
}

List<AudioTone> _toneList(dynamic raw, {String idKey = 'id'}) {
  if (raw is! List) return const [];
  final tones = <AudioTone>[];
  for (final entry in raw) {
    if (entry is Map && idKey != 'id' && entry['id'] == null) {
      final patched = Map<String, dynamic>.from(entry);
      patched['id'] = patched[idKey];
      final tone = AudioTone.fromRaw(patched);
      if (tone != null) tones.add(tone);
      continue;
    }
    final tone = AudioTone.fromRaw(entry);
    if (tone != null) tones.add(tone);
  }
  return List.unmodifiable(tones);
}

Map<String, dynamic>? _resolveData(Map<String, dynamic> payload) {
  dynamic data = payload['data'] ?? payload;
  if (data is Map && data['data'] is Map) data = data['data'];
  if (data is! Map) return null;
  return Map<String, dynamic>.from(data);
}

String _string(dynamic value) => value == null ? '' : '$value'.trim();

int _int(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.isFinite ? value.toInt() : 0;
  if (value is String) return int.tryParse(value.trim()) ?? 0;
  return 0;
}
