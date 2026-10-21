import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 点书入口的分类，决定用哪一条「点书直达阅读器」偏好（issue #103）。
///
/// 书架里的书是用户已经收下的书，点开八成是想接着读；发现入口（首页、
/// 搜索、榜单、作者页…）的书往往还要先看简介再决定，所以两条偏好分开存，
/// 也让官方「书架续读、发现页进详情」的默认分层在客户端可控。
enum BookOpenEntry {
  /// 书架、阅读历史这类「我的书」入口。
  shelf,

  /// 首页、搜索、榜单、作者页、短剧/系列推荐等发现入口。
  discover,
}

/// 「点书直达阅读器」的持久化偏好（issue #19 第 3 条引入，issue #103 拆成
/// 书架/发现两条）。
///
/// 默认值按入口分开：书架那条**默认开**（书架里的书就是「接着读」，官方书架点书
/// 也直接起阅读器），发现入口那条默认关（先看简介再决定更常见）。打开后点书跳过
/// 详情页，直接按上次进度进阅读器；听书/短剧仍进详情页（它们不是「阅读」），
/// 详情页加载失败时也停留在详情页，让用户看到错误与重试。
///
/// 旧版只有一条全局开关 [legacyKey]，[load] 读到旧值且新键都不存在时把它迁移
/// 成「两条同值」，升级后行为不变；旧键本身保留不删，避免回退版本时丢设置。
class BookOpenPreferences {
  BookOpenPreferences._();

  static final BookOpenPreferences instance = BookOpenPreferences._();

  /// 旧版单开关，只用于一次性迁移。
  static const legacyKey = 'book_open_direct_reader';
  static const shelfKey = 'book_open_direct_reader_shelf';
  static const discoverKey = 'book_open_direct_reader_discover';

  /// 书架那条的默认值：开。书架里的书是用户自己收下的，点开就是接着读。
  static const defaultShelfDirectReader = true;

  /// 发现入口那条的默认值：关。先看简介、目录、评分再决定是常态。
  static const defaultDiscoverDirectReader = false;

  /// 书架/阅读历史里点书是否直达阅读器。由 [load] 从 SharedPreferences 读入，
  /// 读完之前是 [defaultShelfDirectReader]。
  final ValueNotifier<bool> shelfDirectReader = ValueNotifier<bool>(
    defaultShelfDirectReader,
  );

  /// 发现入口点书是否直达阅读器。读完之前是 [defaultDiscoverDirectReader]。
  final ValueNotifier<bool> discoverDirectReader = ValueNotifier<bool>(
    defaultDiscoverDirectReader,
  );

  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final sp = await SharedPreferences.getInstance();
      final legacy = sp.getBool(legacyKey);
      final hasShelf = sp.containsKey(shelfKey);
      final hasDiscover = sp.containsKey(discoverKey);
      final shelf = sp.getBool(shelfKey) ?? legacy ?? defaultShelfDirectReader;
      final discover =
          sp.getBool(discoverKey) ?? legacy ?? defaultDiscoverDirectReader;
      shelfDirectReader.value = shelf;
      discoverDirectReader.value = discover;
      if (legacy != null && !hasShelf && !hasDiscover) {
        await _persist(shelf: shelf, discover: discover);
      }
    } catch (_) {
      // A broken optional preference reads as its default.
    }
  }

  /// 忘掉已加载状态，让下一次 [load] 重新读 SharedPreferences。
  ///
  /// 只为测试存在：`_loaded` 是进程级一次性守卫，`setMockInitialValues`
  /// 换掉的初值不会被已加载过的实例重新读取。
  @visibleForTesting
  void resetForTest() {
    _loaded = false;
    shelfDirectReader.value = defaultShelfDirectReader;
    discoverDirectReader.value = defaultDiscoverDirectReader;
  }

  /// 某个入口当前是否直达阅读器。调用前应确保 [load] 已完成。
  bool directReaderFor(BookOpenEntry entry) => switch (entry) {
    BookOpenEntry.shelf => shelfDirectReader.value,
    BookOpenEntry.discover => discoverDirectReader.value,
  };

  Future<void> setShelfDirectReader(bool value) async {
    shelfDirectReader.value = value;
    await _persist(shelf: value);
  }

  Future<void> setDiscoverDirectReader(bool value) async {
    discoverDirectReader.value = value;
    await _persist(discover: value);
  }

  /// 只写传入的键；写失败不影响本次会话内的值。
  Future<void> _persist({bool? shelf, bool? discover}) async {
    try {
      final sp = await SharedPreferences.getInstance();
      if (shelf != null) await sp.setBool(shelfKey, shelf);
      if (discover != null) await sp.setBool(discoverKey, discover);
    } catch (_) {
      // The in-session value still applies; only persistence failed.
    }
  }
}
