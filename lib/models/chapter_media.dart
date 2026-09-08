import 'dart:convert';

import 'package:html/parser.dart' show parseFragment;

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
  });

  final String itemId;
  final String url;
  final String toneId;
  final Duration? duration;
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
        final encryption = stream['encrypt_info'];
        if (encryption is Map && encryption['encrypt'] == true) continue;
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

String? _mediaUrl(dynamic value, String baseUrl) {
  if (value is! String || value.trim().isEmpty) return null;
  final raw = value.trim();
  try {
    final parsed = Uri.parse(raw);
    final resolved = parsed.hasScheme
        ? parsed
        : Uri.parse(baseUrl).resolveUri(parsed);
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
