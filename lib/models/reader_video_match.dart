/// Official VideoTimePointData; mapping keys are novel chapter IDs.
class ReaderVideoMatch {
  static const empty = ReaderVideoMatch(
    seriesId: '',
    lastMatchedChapterId: '',
    chapters: {},
    covers: {},
  );
  const ReaderVideoMatch({
    required this.seriesId,
    required this.lastMatchedChapterId,
    required this.chapters,
    required this.covers,
  });

  final String seriesId;
  final String lastMatchedChapterId;
  final Map<String, ReaderVideoChapter> chapters;
  final Map<String, String> covers;

  bool get available => seriesId.isNotEmpty;

  factory ReaderVideoMatch.fromPayload(Map<String, dynamic> payload) {
    final raw = payload['data'];
    if (raw == null) return empty;
    if (raw is! Map) {
      throw const FormatException('Missing video match data');
    }
    final chapters = <String, ReaderVideoChapter>{};
    final mapping = raw['NovelToVideoMap'];
    if (mapping is Map) {
      for (final entry in mapping.entries) {
        final items = entry.value;
        if (items is! List || items.isEmpty || items.first is! Map) continue;
        final first = items.first as Map;
        final seriesId = _id(first['series_id']);
        final videoId = _id(first['video_id']);
        if (seriesId.isEmpty || videoId.isEmpty) continue;
        chapters[entry.key.toString()] = ReaderVideoChapter(seriesId, videoId);
      }
    }
    final covers = <String, String>{};
    final rawCovers = raw['video_cover_map'];
    if (rawCovers is Map) {
      for (final entry in rawCovers.entries) {
        final url = entry.value;
        if (url is String && url.startsWith(RegExp(r'https?://'))) {
          covers[entry.key.toString()] = url;
        }
      }
    }
    return ReaderVideoMatch(
      seriesId: _id(raw['match_video_id']),
      lastMatchedChapterId: _id(raw['novel_match_max_item_id']),
      chapters: Map.unmodifiable(chapters),
      covers: Map.unmodifiable(covers),
    );
  }

  static String _id(dynamic value) {
    final text = value is String
        ? value
        : value is int
        ? '$value'
        : '';
    return RegExp(r'^[1-9][0-9]{0,19}$').hasMatch(text) ? text : '';
  }
}

class ReaderVideoChapter {
  const ReaderVideoChapter(this.seriesId, this.videoId);

  final String seriesId;
  final String videoId;
}
