import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/media_item.dart';
import 'chapter_text_formatter.dart';
import 'text_replacement_engine.dart';

typedef ReaderFullSearchLoader =
    Future<TextReplacementResult> Function(Chapter chapter);

typedef ReaderFullSearchCancellableLoader =
    Future<TextReplacementResult> Function(
      Chapter chapter,
      ReaderFullSearchCancellation cancellation,
    );

/// Per-query cancellation. Only call [beforeNetworkFetch] after checking caches;
/// local-file reads and shared requests do not consume a network slot.
class ReaderFullSearchCancellation {
  ReaderFullSearchCancellation._(this._pacer);

  final _ReaderFullSearchNetworkPacer _pacer;
  final Completer<void> _cancelled = Completer<void>();
  bool get cancelled => _cancelled.isCompleted;

  void throwIfCancelled() {
    if (cancelled) throw StateError('Search cancelled');
  }

  Future<void> beforeNetworkFetch() => _pacer.acquire(this);

  void _cancel() {
    if (!cancelled) _cancelled.complete();
  }
}

/// Keep the cooldown across query changes, without delaying cache hits. Actual
/// network IO still goes through ApiClient's concurrency/coalescing gate.
class _ReaderFullSearchNetworkPacer {
  _ReaderFullSearchNetworkPacer(this._elapsed);

  final Duration Function()? _elapsed;
  final _clock = Stopwatch()..start();
  Duration? _lastStart;
  Duration get _now => _elapsed?.call() ?? _clock.elapsed;

  Future<void> acquire(ReaderFullSearchCancellation cancellation) async {
    cancellation.throwIfCancelled();
    while (_lastStart != null) {
      final remaining =
          const Duration(milliseconds: 300) - (_now - _lastStart!);
      if (remaining <= Duration.zero) break;
      final ready = Completer<void>();
      final timer = Timer(remaining, ready.complete);
      try {
        await Future.any([ready.future, cancellation._cancelled.future]);
      } finally {
        timer.cancel();
      }
      cancellation.throwIfCancelled();
    }
    _lastStart = _now;
  }
}

/// One hit carries both source anchors and exact paragraph-local display
/// coordinates. Source round trips alone lose hits inside expanded replacements.
class ReaderFullSearchHit {
  const ReaderFullSearchHit({
    required this.chapterIndex,
    required this.chapterId,
    required this.sourceParagraphStart,
    required this.sourceCacheHash,
    required this.sourceCacheLength,
    required this.sourceStart,
    required this.sourceEnd,
    required this.localStart,
    required this.localEnd,
    required this.paragraphLength,
    required this.paragraphHash,
    required this.matchedText,
    required this.excerpt,
    required this.excerptStart,
    required this.excerptEnd,
  });

  final int chapterIndex;
  final String chapterId;
  final int sourceParagraphStart, sourceStart, sourceEnd;
  final int sourceCacheHash, sourceCacheLength;

  bool matchesSource(ChapterContent source) {
    final cache = source.toCacheText();
    return cache.length == sourceCacheLength &&
        cache.hashCode == sourceCacheHash;
  }

  final int localStart, localEnd, paragraphLength, paragraphHash;
  final String matchedText, excerpt;
  final int excerptStart, excerptEnd;

  /// Reject a changed paragraph rather than landing on a nearby occurrence.
  ({int start, int end})? displayRange(String text, int blockStart) {
    if (text.length != paragraphLength ||
        text.hashCode != paragraphHash ||
        localEnd > text.length ||
        text.substring(localStart, localEnd) != matchedText) {
      return null;
    }
    return (start: blockStart + localStart, end: blockStart + localEnd);
  }
}

class ReaderFullSearchGroup {
  ReaderFullSearchGroup({
    required this.chapterIndex,
    required this.chapter,
    required this.count,
    required List<ReaderFullSearchHit> hits,
  }) : hits = List.unmodifiable(hits);

  final int chapterIndex;
  final Chapter chapter;
  final int count;
  final List<ReaderFullSearchHit> hits;
  bool get truncated => count > hits.length;
}

class ReaderFullSearchState {
  const ReaderFullSearchState({
    this.query = '',
    this.scanned = 0,
    this.total = 0,
    this.matchCount = 0,
    this.running = false,
    this.cancelled = false,
    this.groups = const [],
    this.failedChapters = const [],
  });

  final String query;
  final int scanned, total, matchCount;
  final bool running, cancelled;
  final List<ReaderFullSearchGroup> groups;
  final List<Chapter> failedChapters;
  bool get truncated => groups.any((group) => group.truncated);
}

/// Serializes chapter work across query changes, including outstanding loads.
/// Cancelling ignores in-flight results immediately and starts no further loads.
/// It deliberately does not abort a shared chapter request used by the reader.
class ReaderFullSearchController extends ChangeNotifier {
  ReaderFullSearchController({
    required List<Chapter> chapters,
    required this.loadChapter,
    this.loadChapterForSearch,
    Duration Function()? networkElapsed,
    this.maxHitsPerChapter = 100,
    this.maxVisibleHits = 2000,
  }) : chapters = List.unmodifiable(chapters),
       _networkPacer = _ReaderFullSearchNetworkPacer(networkElapsed),
       assert(maxHitsPerChapter > 0),
       assert(maxVisibleHits > 0);

  final List<Chapter> chapters;
  final ReaderFullSearchLoader loadChapter;
  final ReaderFullSearchCancellableLoader? loadChapterForSearch;
  final _ReaderFullSearchNetworkPacer _networkPacer;
  ReaderFullSearchCancellation? _cancellation;
  final int maxHitsPerChapter, maxVisibleHits;
  ReaderFullSearchState get state => _state;
  ReaderFullSearchState _state = const ReaderFullSearchState();
  Future<void>? _pending;
  int _generation = 0;
  bool _disposed = false;

  Future<void> search(String query) {
    _cancellation?._cancel();
    final cancellation = _cancellation = ReaderFullSearchCancellation._(
      _networkPacer,
    );
    final generation = ++_generation;
    final term = query.trim();
    if (term.isEmpty || term.length > 120 || _disposed) {
      if (!_disposed) _publish(const ReaderFullSearchState());
      return Future.value();
    }
    _publish(
      ReaderFullSearchState(query: term, total: chapters.length, running: true),
    );
    final previous = _pending;
    final task = () async {
      // Keeping this await makes rapid edits bounded to one chapter load/scan.
      if (previous != null) await previous;
      if (!_current(generation)) return;
      await _run(term, generation, cancellation);
    }();
    _pending = task;
    return task;
  }

  bool _current(int generation) => !_disposed && generation == _generation;

  Future<void> _run(
    String query,
    int generation,
    ReaderFullSearchCancellation cancellation,
  ) async {
    final groups = <ReaderFullSearchGroup>[];
    final failures = <Chapter>[];
    var matchCount = 0;
    var visibleCount = 0;
    for (var index = 0; index < chapters.length; index++) {
      if (!_current(generation)) return;
      final chapter = chapters[index];
      try {
        final cancellableLoader = loadChapterForSearch;
        final replacement = cancellableLoader == null
            ? await loadChapter(chapter)
            : await cancellableLoader(chapter, cancellation);
        if (!_current(generation)) return;
        // A failed transform would otherwise search different text to the reader.
        if (replacement.error != null) {
          throw StateError(replacement.error!);
        }
        final input = (
          chapter: chapter,
          chapterIndex: index,
          replacement: replacement,
          query: query,
          limit: (maxVisibleHits - visibleCount).clamp(0, maxHitsPerChapter),
        );
        final size = replacement.content.blocks.fold<int>(
          0,
          (sum, block) =>
              sum + (block is ChapterParagraph ? block.text.length : 1),
        );
        final group = size > 64 * 1024
            ? await compute(_scanChapter, input)
            : _scanChapter(input);
        if (!_current(generation)) return;
        if (group.count > 0) {
          groups.add(group);
          matchCount += group.count;
          visibleCount += group.hits.length;
        }
      } catch (_) {
        if (!_current(generation)) return;
        failures.add(chapter);
      }
      _publish(
        ReaderFullSearchState(
          query: query,
          scanned: index + 1,
          total: chapters.length,
          matchCount: matchCount,
          running: index + 1 < chapters.length,
          groups: List.unmodifiable(groups),
          failedChapters: List.unmodifiable(failures),
        ),
      );
      // Yield even when all cached chapters and short scans complete immediately.
      await Future<void>.delayed(Duration.zero);
    }
    if (chapters.isEmpty && _current(generation)) {
      _publish(ReaderFullSearchState(query: query));
    }
  }

  void cancel() {
    _cancellation?._cancel();
    ++_generation;
    if (_disposed || !_state.running) return;
    _publish(
      ReaderFullSearchState(
        query: _state.query,
        scanned: _state.scanned,
        total: _state.total,
        matchCount: _state.matchCount,
        cancelled: true,
        groups: _state.groups,
        failedChapters: _state.failedChapters,
      ),
    );
  }

  void _publish(ReaderFullSearchState value) {
    _state = value;
    notifyListeners();
  }

  @override
  void dispose() {
    _cancellation?._cancel();
    ++_generation;
    _disposed = true;
    super.dispose();
  }
}

typedef _ScanInput = ({
  Chapter chapter,
  int chapterIndex,
  TextReplacementResult replacement,
  String query,
  int limit,
});

ReaderFullSearchGroup _scanChapter(_ScanInput input) {
  final replacement = input.replacement;
  final source = replacement.source;
  final sourceCache = source.toCacheText();
  final sourceCacheHash = sourceCache.hashCode;
  final body = source.withoutLeadingTitle(input.chapter.title);
  final indices = {
    for (var i = 0; i < source.blocks.length; i++) source.blocks[i]: i,
  };
  final pattern = RegExp(
    RegExp.escape(input.query),
    caseSensitive: false,
    unicode: true,
  );
  final hits = <ReaderFullSearchHit>[];
  var count = 0;
  // Same source coordinate system as ReaderChapterLayout: synthetic title,
  // newline-separated body paragraphs, and one U+FFFC per image.
  var sourceOffset = input.chapter.title.isEmpty
      ? 0
      : input.chapter.title.length + 1;
  for (final block in body.blocks) {
    final i = indices[block]!;
    final display = replacement.content.blocks[i];
    if (block is ChapterParagraph && display is ChapterParagraph) {
      final map = replacement.paragraphMaps[i];
      final hash = display.text.hashCode;
      for (final match in pattern.allMatches(display.text)) {
        ++count;
        if (hits.length >= input.limit) continue;
        var from = (match.start - 32).clamp(0, display.text.length);
        var to = (match.end + 48).clamp(0, display.text.length);
        // Do not cut a surrogate pair in a snippet.
        if (from > 0 && _lowSurrogate(display.text.codeUnitAt(from))) --from;
        if (to < display.text.length &&
            _lowSurrogate(display.text.codeUnitAt(to))) {
          ++to;
        }
        final prefix = from > 0 ? '…' : '';
        final excerpt =
            '$prefix${display.text.substring(from, to)}${to < display.text.length ? '…' : ''}';
        hits.add(
          ReaderFullSearchHit(
            chapterIndex: input.chapterIndex,
            chapterId: input.chapter.itemId,
            sourceParagraphStart: sourceOffset,
            sourceCacheHash: sourceCacheHash,
            sourceCacheLength: sourceCache.length,
            sourceStart:
                sourceOffset +
                (map?.toSource(match.start, bias: TextBoundaryBias.start) ??
                    match.start),
            sourceEnd:
                sourceOffset +
                (map?.toSource(match.end, bias: TextBoundaryBias.end) ??
                    match.end),
            localStart: match.start,
            localEnd: match.end,
            paragraphLength: display.text.length,
            paragraphHash: hash,
            matchedText: match.group(0)!,
            excerpt: excerpt,
            excerptStart: prefix.length + match.start - from,
            excerptEnd: prefix.length + match.end - from,
          ),
        );
      }
    }
    sourceOffset += (block is ChapterParagraph ? block.text.length : 1) + 1;
  }
  return ReaderFullSearchGroup(
    chapterIndex: input.chapterIndex,
    chapter: input.chapter,
    count: count,
    hits: hits,
  );
}

bool _lowSurrogate(int value) => value >= 0xDC00 && value <= 0xDFFF;
