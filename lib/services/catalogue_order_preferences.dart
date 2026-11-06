import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 目录正序/倒序的持久化偏好（上游 `DetailPage` 把 `catalogueReversed` 写进
/// `readerPreferences`，跨书、跨会话保留）。
///
/// 上游是每本书一条 reader preferences；fqapp 的详情页目录顺序是全局交互习惯
/// （同一用户看任何书都倾向同一种顺序），因此这里用一个全局键承载，行为与
/// 上游「离开页面后仍保持」一致，但不把阅读器排版偏好耦合进来。
class CatalogueOrderPreferences {
  CatalogueOrderPreferences._();

  static final CatalogueOrderPreferences instance =
      CatalogueOrderPreferences._();

  /// 上游 `readerPreferences.catalogueReversed` 在 fqapp 的存储键。
  static const key = 'detail_catalogue_reversed';

  bool _loaded = false;
  bool _reversed = false;

  /// 目录当前是否倒序。读取前为 false（正序）。
  bool get reversed => _reversed;

  /// 从 SharedPreferences 载入；损坏或缺失时保持正序。
  Future<bool> load() async {
    if (_loaded) return _reversed;
    _loaded = true;
    try {
      final sp = await SharedPreferences.getInstance();
      _reversed = sp.getBool(key) ?? false;
    } catch (_) {
      // 读不到可选偏好时按默认正序处理。
    }
    return _reversed;
  }

  /// 写入并返回是否落盘成功；失败时会话内的值仍然生效。
  Future<bool> save(bool value) async {
    _reversed = value;
    try {
      final sp = await SharedPreferences.getInstance();
      return await sp.setBool(key, value);
    } catch (_) {
      return false;
    }
  }

  /// 忘掉已加载状态，让下一次 [load] 重新读 SharedPreferences。
  ///
  /// 只为测试存在：`_loaded` 是进程级一次性守卫，`setMockInitialValues` 换掉的
  /// 初值不会被已加载过的实例重新读取。
  @visibleForTesting
  void resetForTest() {
    _loaded = false;
    _reversed = false;
  }
}
