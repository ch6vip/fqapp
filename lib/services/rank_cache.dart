import 'dart:async';

import 'package:hive_flutter/hive_flutter.dart';

import '../models/rank.dart';

/// The rank catalogue as previously stored.
class RankCatalogSnapshot {
  final RankCatalog catalog;
  final DateTime savedAt;

  const RankCatalogSnapshot({required this.catalog, required this.savedAt});
}

/// One board's first page as previously stored.
class RankBoardSnapshot {
  final RankBoard board;
  final DateTime savedAt;

  const RankBoardSnapshot({required this.board, required this.savedAt});
}

/// On-disk cache of the rank catalogue and every board's first page.
///
/// Mirrors the short-drama aggregator's rank discipline: a successful result
/// is served from cache for [freshTtl] without touching the network, a stale
/// snapshot renders immediately while the refresh runs, and a failed refresh
/// keeps the cached list instead of an error page. Only first pages are
/// stored — a restored board pages from the network like any other.
class RankCache {
  RankCache({HiveInterface? hive}) : _hive = hive ?? Hive;

  static final RankCache instance = RankCache();
  static const _boxName = 'rank_cache_v1';

  /// A snapshot younger than this is served without a network round trip.
  static const freshTtl = Duration(minutes: 5);

  /// A snapshot older than this is not restored at all; between [freshTtl]
  /// and here the cached list renders while the refresh runs.
  static const staleTtl = Duration(hours: 24);

  /// Set once Hive has a directory (app bootstrap). Widget tests that never
  /// call Hive.initFlutter() leave this false, so nothing touches a box that
  /// cannot be opened yet.
  static bool hiveReady = false;

  final HiveInterface _hive;
  Box<dynamic>? _box;
  Future<Box<dynamic>>? _opening;

  Future<Box<dynamic>> _ensureBox() async {
    final box = _box;
    if (box != null) return box;
    try {
      return _box = await (_opening ??= _hive.openBox(_boxName));
    } on Object {
      _opening = null;
      rethrow;
    }
  }

  /// Opens the box ahead of the first load. Called (and awaited) from app
  /// bootstrap; a failure leaves every load returning null.
  Future<void> warmUp() async {
    _box = null;
    _opening = null;
    if (!hiveReady) return;
    try {
      await _ensureBox();
    } catch (_) {
      _box = null;
    }
  }

  RankCatalogSnapshot? loadCatalog() => _read('catalog', (raw) {
    final catalog = RankCatalog.fromJson(raw);
    return catalog == null
        ? null
        : RankCatalogSnapshot(
            catalog: catalog,
            savedAt: _savedAt(raw),
          );
  });

  RankBoardSnapshot? loadBoard({
    required String rankId,
    required int algo,
    required int categoryId,
  }) => _read('$rankId|$algo|$categoryId', (raw) {
    final board = RankBoard.fromJson(raw);
    return board.isEmpty
        ? null
        : RankBoardSnapshot(board: board, savedAt: _savedAt(raw));
  });

  /// Best-effort writes. A failed cache write must never surface to the page.
  Future<void> saveCatalog(RankCatalog catalog) async {
    if (!hiveReady || catalog.isEmpty) return;
    await _write('catalog', catalog.toJson());
  }

  Future<void> saveBoard({
    required String rankId,
    required int algo,
    required int categoryId,
    required RankBoard board,
  }) async {
    if (!hiveReady || board.isEmpty) return;
    await _write('$rankId|$algo|$categoryId', board.toJson());
  }

  Future<void> _write(String key, Map<String, dynamic> payload) async {
    try {
      final box = await _ensureBox();
      await box.put(key, {
        ...payload,
        'savedAt': DateTime.now().millisecondsSinceEpoch,
      });
    } catch (_) {
      // The next successful load overwrites this entry anyway.
    }
  }

  T? _read<T>(String key, T? Function(Map<String, dynamic> raw) parse) {
    final box = _box;
    if (box == null || !box.isOpen) return null;
    final Object? raw;
    try {
      raw = box.get(key);
    } catch (_) {
      return null;
    }
    if (raw is! Map) return null;
    if (DateTime.now().difference(_savedAt(raw)) > staleTtl) {
      return null;
    }
    try {
      return parse(Map<String, dynamic>.from(raw));
    } catch (_) {
      return null;
    }
  }

  DateTime _savedAt(Map<dynamic, dynamic> raw) {
    final savedAt = raw['savedAt'];
    return savedAt is int
        ? DateTime.fromMillisecondsSinceEpoch(savedAt)
        : DateTime.fromMillisecondsSinceEpoch(0);
  }

  /// Test seam: closes the memoized box so later saves reload fresh storage.
  Future<void> close() async {
    final box = _box;
    _box = null;
    _opening = null;
    try {
      await box?.close();
    } catch (_) {}
  }
}
