/// Chapter ideas (段评 / 章评) from `/api/v1/chapters/{id}/reviews`
/// (upstream `POST /novel/commentapi/idea/list/{item_id}/v1/`).
///
/// Verified live shape: `data.data` is a map keyed by **paragraph index**, and
/// each entry carries the idea `count`, the per-channel bubble counters
/// (`bubble_data`, keyed by UgcCommentChannelEnum value) and an `infos` list.
/// The upstream fills `infos` with `comment_id` references only — the comment
/// bodies live behind the comment-list endpoint — so this model deliberately
/// exposes counts and ids rather than pretending to have the text.
library;

/// Ideas anchored to one paragraph of a chapter.
class ParagraphIdeas {
  const ParagraphIdeas({
    required this.paraIndex,
    this.count = 0,
    this.commentIds = const [],
    this.channelCounts = const {},
  });

  /// The paragraph ordinal used as the key in the upstream response.
  final int paraIndex;

  /// Number of ideas on this paragraph.
  final int count;

  /// Comment ids; resolve them through the comment-list endpoint for bodies.
  final List<String> commentIds;

  /// Bubble counters by `UgcCommentChannelEnum` value. The reader shows a badge
  /// only for the channel it is displaying, so a paragraph can have `count > 0`
  /// while the paragraph-comment channel reports `0`.
  final Map<int, int> channelCounts;

  bool get hasIdeas => count > 0;

  /// Count for one channel, or 0 when the upstream did not report it.
  int countForChannel(int channel) => channelCounts[channel] ?? 0;

  /// Whether the reader should draw an in-text bubble for this paragraph.
  ///
  /// Any paragraph with ideas gets one. The official client also carries a
  /// narrower gate — `bubble_data[3].count > 0`, applied only while its
  /// `para_comment_featured_v697` switch is on (off by default) — but following
  /// it here was wrong: the flag is off in the shipped app, and the gate is far
  /// stricter than it looks, since a paragraph can carry ideas on another
  /// channel while `bubble_data[3].count` is 0. On real chapters it passed 21 of
  /// 48 paragraphs for one book and 1 of 36 for another, which is exactly the
  /// "why does only the first paragraph have comments" symptom.
  ///
  /// See .agents/notes/implemented/feature/2026-09-11-reader-paragraph-bubble.md
  bool get showsBubble => hasIdeas;

  /// The `bubble_data` key the official gate reads. Kept for reference so the
  /// channel semantics stay documented next to the decision.
  static const bubbleGateChannel = 3;
}

/// Every paragraph idea bucket for one chapter.
class ChapterIdeas {
  const ChapterIdeas({this.itemVersion = '', this.paragraphs = const []});

  static const empty = ChapterIdeas();

  /// Chapter content version the upstream echoed back.
  final String itemVersion;

  final List<ParagraphIdeas> paragraphs;

  bool get isEmpty => paragraphs.isEmpty;
  bool get isNotEmpty => paragraphs.isNotEmpty;

  /// Paragraphs that actually carry ideas, in ascending paragraph order.
  List<ParagraphIdeas> get withIdeas => [
    for (final p in paragraphs)
      if (p.hasIdeas) p,
  ];

  /// Paragraph count to print in each in-text bubble, keyed by paragraph id.
  ///
  /// Only paragraphs that pass [ParagraphIdeas.showsBubble] appear, and the
  /// value is the paragraph's total count (not the gated channel's).
  Map<int, int> get bubbleCounts => {
    for (final p in paragraphs)
      if (p.showsBubble) p.paraIndex: p.count,
  };

  /// Total idea count across the chapter.
  int get total {
    var sum = 0;
    for (final p in paragraphs) {
      sum += p.count;
    }
    return sum;
  }

  ParagraphIdeas? forParagraph(int paraIndex) {
    for (final p in paragraphs) {
      if (p.paraIndex == paraIndex) return p;
    }
    return null;
  }

  /// Parses the endpoint payload. Accepts `{code, data}` with `data.data` as the
  /// paragraph map; a business error (e.g. an unknown item) yields [empty].
  static ChapterIdeas fromPayload(Map<String, dynamic> payload) {
    if (isUnavailableIdeaCode(payload['code'])) return empty;
    final data = _resolveData(payload);
    if (data == null) return empty;
    final buckets = data['data'];
    if (buckets is! Map) return empty;
    final paragraphs = <ParagraphIdeas>[];
    for (final entry in buckets.entries) {
      final paraIndex = int.tryParse('${entry.key}');
      final value = entry.value;
      if (paraIndex == null || value is! Map) continue;
      paragraphs.add(
        ParagraphIdeas(
          paraIndex: paraIndex,
          count: _int(value['count']),
          commentIds: _commentIds(value['infos']),
          channelCounts: _channelCounts(value['bubble_data']),
        ),
      );
    }
    if (paragraphs.isEmpty) return empty;
    paragraphs.sort((a, b) => a.paraIndex.compareTo(b.paraIndex));
    return ChapterIdeas(
      itemVersion: '${data['item_version'] ?? ''}',
      paragraphs: List.unmodifiable(paragraphs),
    );
  }
}

/// Ideas endpoints answer with a business code instead of a body when the item
/// has none; treat those as "no ideas" rather than a failure.
bool isUnavailableIdeaCode(dynamic code) {
  const unavailable = {103001, 1301008};
  final value = code is int ? code : int.tryParse('$code');
  return value != null && unavailable.contains(value);
}

List<String> _commentIds(dynamic infos) {
  if (infos is! List) return const [];
  final ids = <String>[];
  for (final info in infos) {
    if (info is! Map) continue;
    final id = '${info['comment_id'] ?? ''}'.trim();
    if (id.isNotEmpty) ids.add(id);
  }
  return List.unmodifiable(ids);
}

Map<int, int> _channelCounts(dynamic bubble) {
  if (bubble is! Map) return const {};
  final counts = <int, int>{};
  for (final entry in bubble.entries) {
    final channel = int.tryParse('${entry.key}');
    final value = entry.value;
    if (channel == null || value is! Map) continue;
    counts[channel] = _int(value['count']);
  }
  return Map.unmodifiable(counts);
}

Map<String, dynamic>? _resolveData(Map<String, dynamic> payload) {
  dynamic data = payload['data'] ?? payload;
  if (data is! Map) return null;
  return Map<String, dynamic>.from(data);
}

int _int(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim()) ?? 0;
  return 0;
}
