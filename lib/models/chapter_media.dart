import 'dart:convert';

import 'package:html/parser.dart' show parseFragment;

import 'backend_resource_url.dart';

/// An available voice ID; ordinary book detail's CSV has no display names.
class AudioVoice {
  const AudioVoice({required this.id, required this.label});

  final String id;
  final String label;
}

/// A playable chapter with an optional duration from playback metadata.
class AudioSource {
  const AudioSource({
    required this.itemId,
    required this.url,
    this.toneId = '0',
    this.duration,
    this.keyHex = '',
  });

  final String itemId;
  final String url;
  final String toneId;
  final Duration? duration;

  /// 16-byte CENC content key in hex, empty for plain streams.
  ///
  /// Hearing-native albums are answered with cenc-aes-ctr streams; the backend
  /// derives this key from `encrypt_info.spade_a` and the native player feeds
  /// it to the same AES-CTR path the short-play episodes already use.
  final String keyHex;
}

/// A comic page in reading order. URL-only responses leave dimensions unset.
class ComicImage {
  const ComicImage({
    required this.url,
    this.width,
    this.height,
    this.headers = const {},
  });

  final String url;
  final int? width;
  final int? height;
  final Map<String, String> headers;
}

const defaultAudioVoices = [AudioVoice(id: '0', label: '默认音色')];

/// Parses the official playinfo response (GET /reading/reader/audio/playinfo):
/// a flat array of streams with top-level `main_url` plus a nested
/// `video_model` JSON string carrying `encrypt_info.key_hex` (the backend
/// derives it from `spade_a`). This endpoint — unlike the legacy
/// video_model/mget bridge — honours the requested `tone_id`, so switching
/// 智能朗读 actually changes the answered stream.
/// See .agents/notes/implemented/bug-fix/2026-09-16-cross-review-boundaries.md.
AudioSource parsePlayinfoSource(
  Map<String, dynamic> payload, {
  required String itemId,
  required String baseUrl,
  String toneId = '0',
}) {
  final streams = _checkedMediaObjects(payload).last['data'];
  if (streams is! List) throw const FormatException('未获取到音频地址');
  for (final stream in streams) {
    if (stream is! Map) continue;
    final streamItemId = stream['item_id'];
    if (streamItemId != null && streamItemId.toString() != itemId) continue;
    // An upstream business error (code != 0) inside the stream row wins over
    // an otherwise valid media row, as with the mget bridge.
    final code = stream['code'];
    if ((code != null && code != 0 && code != 200) ||
        stream['success'] == false) {
      final message = stream['message'];
      throw FormatException(
        message is String && message.isNotEmpty ? message : '音频资源暂不可用',
      );
    }
    final rawModel = stream['video_model'];
    if (rawModel == null) {
      // Older direct responses need no model, but any supplied encryption
      // metadata must still be usable. A malformed model is not a plain URL.
      final keyHex = _streamContentKey(stream['encrypt_info']);
      final url =
          _mediaUrl(stream['main_url'], baseUrl) ??
          _mediaUrl(stream['backup_url'], baseUrl);
      if (keyHex == null || url == null) continue;
      return AudioSource(
        itemId: itemId,
        url: url,
        toneId: toneId,
        keyHex: keyHex,
      );
    }
    final model = _playinfoModel(rawModel);
    if (model == null) continue;
    if (model['media_type'] != null && model['media_type'] != 'audio') continue;
    if (model['status'] != null && model['status'] != 10) {
      final message = model['message'];
      throw FormatException(
        message is String && message.isNotEmpty ? message : '音频资源暂不可用',
      );
    }
    final selected = _playinfoStream(stream, model, baseUrl);
    if (selected == null) continue;
    return AudioSource(
      itemId: itemId,
      url: selected.url,
      toneId: toneId,
      // Only `video_duration` is specified in audio seconds; `indate` is not a
      // duration fallback (real responses use 86400 beside 664.74 seconds).
      duration: _playinfoDuration(model['video_duration']),
      keyHex: selected.keyHex,
    );
  }
  throw const FormatException('未获取到音频地址');
}

Map<String, dynamic>? _playinfoModel(dynamic raw) {
  if (raw is! String || raw.trim().isEmpty) return null;
  try {
    final decoded = jsonDecode(raw);
    return decoded is Map<String, dynamic> ? decoded : null;
  } on FormatException {
    return null;
  }
}

/// Keeps each URL with its own encryption metadata. Prefer the outer URL only
/// when it exactly matches a usable model stream; otherwise use a model URL.
({String url, String keyHex})? _playinfoStream(
  Map<dynamic, dynamic> row,
  Map<String, dynamic> model,
  String baseUrl,
) {
  final streams = model['video_list'];
  if (streams is! List) return null;
  final candidates = <({String url, String keyHex})>[];
  for (final stream in streams) {
    if (stream is! Map) continue;
    final keyHex = _streamContentKey(stream['encrypt_info']);
    if (keyHex == null) continue;
    for (final field in ['main_url', 'backup_url']) {
      final url = _mediaUrl(stream[field], baseUrl);
      if (url != null) candidates.add((url: url, keyHex: keyHex));
    }
  }
  for (final field in ['main_url', 'backup_url']) {
    final preferred = _mediaUrl(row[field], baseUrl);
    if (preferred == null) continue;
    for (final candidate in candidates) {
      if (candidate.url == preferred) return candidate;
    }
  }
  return candidates.isEmpty ? null : candidates.first;
}

Duration? _playinfoDuration(dynamic seconds) {
  if (seconds is! num || !seconds.isFinite || seconds <= 0) return null;
  final microseconds = seconds.toDouble() * Duration.microsecondsPerSecond;
  if (!microseconds.isFinite || microseconds >= 9223372036854775807) {
    return null;
  }
  return Duration(microseconds: microseconds.round());
}

/// Parses the audio playback model, or an older bridge's direct audio URL.
/// `video_duration` in the playback model is measured in seconds; no unit is
/// assumed for unrelated duration fields in the legacy speech response.
AudioSource parseAudioSource(
  Map<String, dynamic> payload, {
  required String itemId,
  required String baseUrl,
  String toneId = '0',
}) {
  final objects = _checkedMediaObjects(payload);
  final playback = payload['video_info'];
  if (playback is Map) {
    return _parseAudioPlayback(
      Map<String, dynamic>.from(playback),
      itemId: itemId,
      toneId: toneId,
      baseUrl: baseUrl,
    );
  }
  for (final object in objects) {
    final url = _mediaUrl(object['audio_url'], baseUrl);
    if (url != null) {
      return AudioSource(itemId: itemId, url: url, toneId: toneId);
    }
  }
  throw const FormatException('未获取到音频地址');
}

AudioSource _parseAudioPlayback(
  Map<String, dynamic> playback, {
  required String itemId,
  required String toneId,
  required String baseUrl,
}) {
  for (final object in _checkedMediaObjects(playback)) {
    final rows = object['video_model_datas'];
    if (rows is! List) continue;
    for (final row in rows) {
      if (row is! Map || row['item_id']?.toString() != itemId) continue;
      final itemStatus = row['item_status'];
      if (itemStatus != null && itemStatus != 0) {
        throw const FormatException('该章节暂时无法播放');
      }
      final rawModel = row['video_model'];
      if (rawModel is! String || rawModel.trim().isEmpty) continue;
      final model = jsonDecode(rawModel);
      if (model is! Map || model['media_type'] != 'audio') continue;
      if (model['status'] != null && model['status'] != 10) {
        final message = model['message'];
        throw FormatException(
          message is String && message.isNotEmpty ? message : '音频资源暂不可用',
        );
      }
      final streams = model['video_list'];
      if (streams is! List) continue;
      for (final stream in streams) {
        if (stream is! Map) continue;
        final keyHex = _streamContentKey(stream['encrypt_info']);
        if (keyHex == null) continue;
        final url =
            _mediaUrl(stream['main_url'], baseUrl) ??
            _mediaUrl(stream['backup_url'], baseUrl);
        if (url == null) continue;
        final seconds = model['video_duration'];
        final microseconds = seconds is num
            ? seconds.toDouble() * Duration.microsecondsPerSecond
            : null;
        final duration =
            microseconds != null &&
                microseconds.isFinite &&
                microseconds > 0 &&
                microseconds < 9223372036854775807
            ? Duration(microseconds: microseconds.round())
            : null;
        return AudioSource(
          itemId: itemId,
          url: url,
          toneId: toneId,
          duration: duration,
          keyHex: keyHex,
        );
      }
    }
  }
  throw const FormatException('未获取到音频地址');
}

/// Ordinary book detail exposes voice IDs as a CSV string, without names.
/// Keep the default available even when detail omits it or has no voice data.
List<AudioVoice> parseAudioVoices(Map<String, dynamic> payload) {
  final ids = <String>{'0'};
  for (final object in _checkedMediaObjects(payload)) {
    final tones = object['tones'];
    if (tones is! String) continue;
    ids.addAll(
      tones.split(',').map((id) => id.trim()).where((id) => id.isNotEmpty),
    );
    break;
  }
  return List.unmodifiable([
    for (final id in ids)
      AudioVoice(id: id, label: id == '0' ? '默认音色' : '音色 $id'),
  ]);
}

/// The committed backend returns an ordered URL array. Some content fallback
/// responses carry HTML instead; extract its image sources without rendering
/// markup. Repeated URLs remain separate pages in the original reading order.
List<ComicImage> parseComicImages(
  Map<String, dynamic> payload, {
  required String baseUrl,
}) {
  final objects = _checkedMediaObjects(payload);
  for (final object in objects) {
    final images = object['images'];
    if (images is! List) continue;
    final pages = <ComicImage>[];
    for (final value in images) {
      final url = _mediaUrl(value, baseUrl);
      if (url != null) pages.add(ComicImage(url: url));
    }
    if (pages.isNotEmpty) return List.unmodifiable(pages);
  }
  for (final object in objects) {
    for (final key in ['content', 'images']) {
      final html = object[key];
      if (html is! String || !html.toLowerCase().contains('<img')) continue;
      final pages = <ComicImage>[];
      for (final element in parseFragment(html).querySelectorAll('img')) {
        final url = _mediaUrl(element.attributes['src'], baseUrl);
        if (url != null) pages.add(ComicImage(url: url));
      }
      if (pages.isNotEmpty) return List.unmodifiable(pages);
    }
  }
  throw const FormatException('未获取到漫画图片');
}

/// A web `code=200` envelope can contain an upstream business error. Check
/// every known `data` wrapper before accepting even an apparently valid URL.
List<Map<dynamic, dynamic>> _checkedMediaObjects(Map<String, dynamic> payload) {
  final objects = <Map<dynamic, dynamic>>[];
  Map<dynamic, dynamic> current = payload;
  for (var depth = 0; depth < 8; depth++) {
    final code = current['code'];
    if ((code != null && code != 0 && code != 200) ||
        current['success'] == false) {
      final message = current['message'] ?? current['error'];
      throw FormatException(
        message is String && message.trim().isNotEmpty ? message : '媒体请求失败',
      );
    }
    objects.add(current);
    final next = current['data'];
    if (next is! Map) return objects;
    current = next;
  }
  throw const FormatException('媒体响应嵌套过深');
}

final _contentKeyPattern = RegExp(r'^[0-9a-f]{32}$');

/// Resolves one stream's CENC content key, or `null` when the stream must be
/// skipped.
///
/// A plain stream needs no key and yields an empty string. An encrypted stream
/// is only playable once the backend derived `encrypt_info.key_hex` from
/// `spade_a`; without it the native player has no AES-CTR key, so the stream
/// still has to be skipped and the caller falls back to the next one — or
/// reports "未获取到音频地址" when none is left.
String? _streamContentKey(dynamic encryption) {
  if (encryption is! Map) return '';
  if (encryption['encrypt'] != true) return '';
  // The native core implements the cenc AES-CTR scheme only.
  final method = encryption['encryption_method'];
  if (method is String && method.isNotEmpty && method != 'cenc-aes-ctr') {
    return null;
  }
  final raw = encryption['key_hex'];
  if (raw is! String) return null;
  final key = raw.trim().toLowerCase();
  return _contentKeyPattern.hasMatch(key) ? key : null;
}

String? _mediaUrl(dynamic value, String baseUrl) {
  if (value is! String || value.trim().isEmpty) return null;
  final raw = value.trim();
  try {
    final parsed = Uri.parse(raw);
    final resolved = parsed.hasScheme
        ? parsed
        : Uri.parse(resolveBackendResource(baseUrl, raw));
    if ((resolved.scheme != 'http' && resolved.scheme != 'https') ||
        resolved.host.isEmpty) {
      return null;
    }
    // Avoid rewriting the query of an absolute signed CDN URL.
    return parsed.hasScheme ? raw : resolved.toString();
  } on FormatException {
    return null;
  }
}
