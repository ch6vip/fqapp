import 'dart:async';
import 'dart:convert';

import '../models/media_item.dart';
import 'api_client.dart';

class EpisodeSource {
  final String url;
  final String keyHex;

  const EpisodeSource(this.url, [this.keyHex = '']);

  factory EpisodeSource.fromResponse(Map<String, dynamic> response) {
    final data = response['data'] is Map
        ? Map<String, dynamic>.from(response['data'] as Map)
        : response;
    var rawUrl = (data['video_url'] ?? data['main_url'] ?? '')
        .toString()
        .trim();
    if (rawUrl.isEmpty) rawUrl = _extractVideoUrl(response);
    if (rawUrl.isEmpty) throw ApiException('获取播放地址失败');
    return EpisodeSource(
      ApiClient.instance.absoluteUrl(rawUrl),
      (data['key_hex'] ?? '').toString().trim(),
    );
  }
}

enum EpisodeSourceOrigin {
  network,
  cacheHit,
  pending,
  prefetchHit,
  prefetchPending,
}

class EpisodeSourceRequest {
  final Future<EpisodeSource> future;
  final EpisodeSourceOrigin origin;

  const EpisodeSourceRequest(this.future, this.origin);
}

/// Page-local address metadata only. Never creates a player or downloads video.
/// Completed entries are bounded; outstanding demand requests remain joinable
/// until they finish, even if a quick swipe temporarily leaves their episode.
class EpisodeSourceCache {
  static const timeToLive = Duration(minutes: 2);
  static const capacity = 2;

  final Future<EpisodeSource> Function(Chapter) _loader;
  final Duration Function() _now;
  final _ready = <String, _SourceEntry>{};
  final _pending = <String, _SourceEntry>{};
  Set<String>? _retained;
  Future<void>? _prefetching;
  bool _disposed = false;

  EpisodeSourceCache({required this._loader, Duration Function()? now})
    : _now = now ?? _monotonicClock();

  void retainOnly(Set<String> ids) {
    _retained = Set.of(ids);
    _ready.removeWhere((id, _) => !ids.contains(id));
  }

  EpisodeSourceRequest request(Chapter chapter, {bool refresh = false}) =>
      _request(chapter, refresh: refresh, prefetch: false);

  EpisodeSourceRequest _request(
    Chapter chapter, {
    bool refresh = false,
    required bool prefetch,
  }) {
    if (_disposed) throw StateError('Episode source cache is disposed');
    final id = chapter.itemId;
    if (refresh) invalidate(id);
    _ready.removeWhere((_, entry) => !_fresh(entry));
    final ready = _ready.remove(id);
    if (ready != null) {
      _ready[id] = ready;
      return EpisodeSourceRequest(
        ready.future,
        ready.prefetched
            ? EpisodeSourceOrigin.prefetchHit
            : EpisodeSourceOrigin.cacheHit,
      );
    }
    final pending = _pending[id];
    if (pending != null && _fresh(pending)) {
      return EpisodeSourceRequest(
        pending.future,
        pending.prefetched
            ? EpisodeSourceOrigin.prefetchPending
            : EpisodeSourceOrigin.pending,
      );
    }
    final entry = _SourceEntry(_now(), prefetch);
    _pending[id] = entry;
    entry.future = Future.sync(() => _loader(chapter)).then(
      (source) {
        if (!_disposed && identical(_pending[id], entry)) {
          _pending.remove(id);
          if (_fresh(entry) && (_retained?.contains(id) ?? true)) {
            _ready[id] = entry;
            while (_ready.length > capacity) {
              _ready.remove(_ready.keys.first);
            }
          }
        }
        return source;
      },
      onError: (Object error, StackTrace stack) {
        if (identical(_pending[id], entry)) _pending.remove(id);
        Error.throwWithStackTrace(error, stack);
      },
    );
    return EpisodeSourceRequest(entry.future, EpisodeSourceOrigin.network);
  }

  /// Only one speculative request may be in flight. A queued request checks
  /// the page's lifecycle/selection again before it is allowed to start.
  /// Speculative failures are silent and evicted so demand can retry normally.
  Future<void> prefetch(
    Chapter chapter, {
    required bool Function() stillWanted,
  }) async {
    while (_prefetching != null) {
      await _prefetching;
      if (_disposed) return;
    }
    if (_disposed || !stillWanted()) return;
    final request = _request(chapter, prefetch: true);
    final pending = request.future.then<void>((_) {}, onError: (Object _) {});
    _prefetching = pending;
    await pending;
    if (identical(_prefetching, pending)) _prefetching = null;
  }

  bool _fresh(_SourceEntry entry) => _now() - entry.started < timeToLive;

  void invalidate(String id) {
    _ready.remove(id);
    // A late result from this request cannot replace a refreshed entry.
    _pending.remove(id);
  }

  void dispose() {
    _disposed = true;
    _ready.clear();
    _pending.clear();
    _retained = null;
  }
}

class _SourceEntry {
  final Duration started;
  final bool prefetched;
  late final Future<EpisodeSource> future;

  _SourceEntry(this.started, this.prefetched);
}

Duration Function() _monotonicClock() {
  final watch = Stopwatch()..start();
  return () => watch.elapsed;
}

// Compatibility with older backends without normalized stream metadata.
String _extractVideoUrl(Map<String, dynamic> payload) {
  String visit(dynamic value, [int depth = 0]) {
    if (depth > 7 || value == null) return '';
    if (value is String) {
      final trimmed = value.trim();
      if (trimmed.startsWith('http://') ||
          trimmed.startsWith('https://') ||
          trimmed.startsWith('/src/')) {
        return trimmed;
      }
      if (trimmed.startsWith('{')) {
        try {
          return visit(jsonDecode(trimmed), depth + 1);
        } catch (_) {
          return '';
        }
      }
      return '';
    }
    if (value is List) {
      for (final item in value.reversed) {
        final found = visit(item, depth + 1);
        if (found.isNotEmpty) return found;
      }
      return '';
    }
    if (value is Map) {
      for (final key in ['video_url', 'play_url', 'main_url', 'url']) {
        final found = visit(value[key], depth + 1);
        if (found.isNotEmpty) return found;
      }
      for (final key in [
        'data',
        'video_info',
        'video_list',
        'play_info_list',
        'video_model',
      ]) {
        final found = visit(value[key], depth + 1);
        if (found.isNotEmpty) return found;
      }
      for (final nested in value.values) {
        final found = visit(nested, depth + 1);
        if (found.isNotEmpty) return found;
      }
    }
    return '';
  }

  return visit(payload);
}
