import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import '../models/media_item.dart';

/// The device-local 点赞 collection of the 短剧 feed.
///
/// The official client keeps likes on the account: `SeriesDiggView` posts to the
/// digg endpoint and answers with 「点赞成功，可在「我的-我的点赞」查看」
/// (`@string/bzl`) or 「已赞，可在[我的-赞过的短剧]中查看」 (`@string/bzk`).
///  has no per-series digg endpoint and this app has no login, so the like
/// is a Hive box next to the shelf — the same degradation 追剧 already made.
/// Only the *state* (liked / not liked) is stored; there is no count to show,
/// because the backend exposes none (`SeriesDetail` carries `series_play_cnt`
/// and `followed_cnt` only).
///
/// Note: 官方点赞在账号侧、这里退化为本地集合的理由 — 见
/// docs/research/short-drama-decompile-comparison-20260921.md §8.4
class DiggStore {
  DiggStore._();

  static final DiggStore instance = DiggStore._();

  static const boxName = 'digg';
  static const _keyPrefix = 'digg_v1:';

  Box<dynamic>? _box;
  final ValueNotifier<int> _revision = ValueNotifier<int>(0);

  /// Bumps on every write; the feed rebuilds from it.
  ValueListenable<int> get listenable => _revision;

  bool get isReady => _openBox != null;

  /// The box, but only while it is usable — the same rule `ShelfStore` follows,
  /// so a closed box reads as "nothing liked" instead of throwing out of every
  /// card on the page.
  Box<dynamic>? get _openBox {
    final box = _box;
    return box != null && box.isOpen ? box : null;
  }

  /// The series id wins over the item id, for the same reason the shelf prefers
  /// it: a drama opened from one episode must still be one entry.
  static String keyOf(MediaItem item) =>
      '$_keyPrefix${item.kind}:${item.seriesId ?? item.id}';

  Future<void> init() async {
    if (_openBox != null) return;
    _box = await Hive.openBox<dynamic>(boxName);
    _revision.value++;
  }

  bool containsItem(MediaItem item) =>
      _openBox?.containsKey(keyOf(item)) ?? false;

  /// Adds the like, or removes it when already liked.
  /// Returns true when the item is liked afterwards.
  Future<bool> toggle(MediaItem item) async {
    final box = _openBox;
    if (box == null) return false;
    final key = keyOf(item);
    if (box.containsKey(key)) {
      await box.delete(key);
      _revision.value++;
      return false;
    }
    await box.put(key, {
      'id': item.id,
      'kind': item.kind,
      'title': item.title,
      'seriesId': item.seriesId,
      'time': DateTime.now().millisecondsSinceEpoch,
    });
    _revision.value++;
    return true;
  }

  Future<void> clear() async {
    final box = _openBox;
    if (box == null) return;
    await box.clear();
    _revision.value++;
  }
}
