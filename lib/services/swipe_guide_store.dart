import 'package:hive/hive.dart';

/// Whether the 短剧 feed's 「上滑查看更多视频」 guide has been shown.
///
/// The official client persists the flag in SharedPreferences
/// `series_show_user_guide` (`wp3/d0.java`): `SeriesBookMallTabFragment.Ge()`
/// gates the guide on `!c()` and `pp3.f.a.onShow()` writes it back with
/// `d(true)` — so the guide shows **once per install**, never again. This app
/// keeps the same one-shot semantics in a Hive box, with the same degradation
/// rule as [DiggStore]: an unavailable box reads as "not shown yet" and writes
/// are dropped instead of throwing out of the feed.
///
/// Note: 官方一次性提示的完整行为 — 见
/// docs/short-drama-decompile-comparison-20260921.md §19
class SwipeGuideStore {
  SwipeGuideStore._();

  static final SwipeGuideStore instance = SwipeGuideStore._();

  static const boxName = 'guide';
  static const _key = 'swipe_up_shown_v1';

  Box<dynamic>? _box;

  Box<dynamic>? get _openBox {
    final box = _box;
    return box != null && box.isOpen ? box : null;
  }

  Future<void> init() async {
    if (_openBox != null) return;
    _box = await Hive.openBox<dynamic>(boxName);
  }

  bool get shown => _openBox?.get(_key) == true;

  Future<void> markShown() async {
    final box = _openBox;
    if (box == null) return;
    await box.put(_key, true);
  }

  /// Test seam: forget the flag so a case can exercise the first-run path.
  Future<void> reset() async {
    final box = _openBox;
    if (box == null) return;
    await box.delete(_key);
  }
}
