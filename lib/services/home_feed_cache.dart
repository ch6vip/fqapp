import 'dart:async';

import 'package:hive_flutter/hive_flutter.dart';

import '../models/media_item.dart';

/// The last rendered page set of one home tab, as previously stored.
class HomeFeedSnapshot {
  final List<MediaItem> items;
  final bool hasMore;
  final DateTime savedAt;

  const HomeFeedSnapshot({
    required this.items,
    required this.hasMore,
    required this.savedAt,
  });
}

/// On-disk cache of the home tabs' last rendered feeds.
///
/// Cold start and first visits of a tab render the stored snapshot immediately
/// while the network refresh runs; a failed refresh keeps the snapshot visible
/// instead of an empty error page. This is display state only — pagination
/// cursors are never restored, so a restored tab always refreshes from page
/// one, exactly like the stale-while-revalidate catalogue cache it borrows
/// from.
class HomeFeedCache {
  HomeFeedCache({HiveInterface? hive}) : _hive = hive ?? Hive;

  static final HomeFeedCache instance = HomeFeedCache();
  static const _boxName = 'home_feed_cache_v1';

  /// Snapshots older than this are not restored. The refresh always replaces
  /// them, so the bound only stops a long-absent user from being shown an
  /// ancient feed while the network spins.
  static const ttl = Duration(days: 3);

  /// Upper bound on stored cards per tab. The feed itself can page far beyond
  /// this; the cache only exists to make a restart feel instant.
  static const maxItems = 120;

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

  /// Opens the box ahead of the first [load]. Called (and awaited) from app
  /// bootstrap; a failure leaves [load] returning null and the feed simply
  /// starts cold. Memoized state is reset first, so a caller that closed the
  /// underlying Hive directory (tests do) reopens cleanly.
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

  HomeFeedSnapshot? load(int tabIndex) {
    final box = _box;
    if (box == null || !box.isOpen) return null;
    final Object? raw;
    try {
      raw = box.get('$tabIndex');
    } catch (_) {
      return null;
    }
    if (raw is! Map) return null;
    final savedAt = raw['savedAt'];
    if (savedAt is! int) return null;
    final age = DateTime.now().millisecondsSinceEpoch - savedAt;
    if (age < 0 || age > ttl.inMilliseconds) return null;
    final itemsRaw = raw['items'];
    if (itemsRaw is! List) return null;
    final items = <MediaItem>[];
    for (final entry in itemsRaw) {
      if (entry is Map) {
        try {
          final item = MediaItemJson.fromJson(
            Map<String, dynamic>.from(entry),
          );
          if (item != null) items.add(item);
        } catch (_) {
          // One unreadable card is skipped; the rest still render.
        }
      }
    }
    if (items.isEmpty) return null;
    return HomeFeedSnapshot(
      items: items,
      hasMore: raw['hasMore'] != false,
      savedAt: DateTime.fromMillisecondsSinceEpoch(savedAt),
    );
  }

  /// Best-effort write. A failed cache write must never surface to the feed.
  Future<void> save(
    int tabIndex,
    List<MediaItem> items, {
    required bool hasMore,
  }) async {
    if (!hiveReady || items.isEmpty) return;
    try {
      final box = await _ensureBox();
      await box.put('$tabIndex', {
        'v': 1,
        'savedAt': DateTime.now().millisecondsSinceEpoch,
        'hasMore': hasMore,
        'items': items.take(maxItems).map((item) => item.toJson()).toList(),
      });
    } catch (_) {
      // The next successful load overwrites this entry anyway.
    }
  }

  /// Test seam: closes the memoized box so a later save reloads fresh storage.
  Future<void> close() async {
    final box = _box;
    _box = null;
    _opening = null;
    try {
      await box?.close();
    } catch (_) {}
  }
}
