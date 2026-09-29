import 'package:shared_preferences/shared_preferences.dart';

/// 短剧播放页字号档位（官方 `jk3/a` 的 标准/大号/超大号）。
///
/// 官方行为（`nm3/e` 字号弹层 + `jk3/b` 管理器）：
/// - 三档系数 `eh3/c`：标准 1.0、大号 1.15、超大号 1.3；
/// - 缩放对象是**播放页 UI 文本**（`ShortSeriesScaleTextView` 覆盖标题/
///   选集条/热评/评论等），弹幕不受影响（弹幕有自己的字号配置）；
/// - 持久化 SP `short_series_font_scale_manager` 的
///   `current_selected_index`（`jk3/b` 静态块），默认 0（标准）。
///
/// 本仓库把系数作用在 chrome 子树的 TextScaler 上：Text 会按
/// MediaQuery 的 textScaler 缩放 fontSize，与官方逐处乘系数等价；
/// 弹幕层在 chrome 内单独还原外层 scaler 以豁免。
class ShortSeriesFontScale {
  const ShortSeriesFontScale._();

  static const spName = 'short_series_font_scale_manager';
  static const spKey = 'current_selected_index';

  /// 档位系数（`eh3/c`：c=1.0 / b=1.15 / a=1.3）。
  static const factors = <double>[1.0, 1.15, 1.3];

  /// 官方档位文案（`jk3/a` 静态块）。
  static const labels = <String>['标准', '大号', '超大号'];

  /// Process-wide value；tests assign directly（与 PlayerStyleConfig 同约定）。
  static int instance = 0;

  static double get scale => factors[instance.clamp(0, factors.length - 1)];

  static String get label => labels[instance.clamp(0, labels.length - 1)];

  static Future<void> load() async {
    try {
      final store = await SharedPreferences.getInstance();
      instance = (store.getInt('$spName/$spKey') ?? 0).clamp(0, 2);
    } catch (_) {
      instance = 0;
    }
  }

  static Future<void> save(int index) async {
    instance = index.clamp(0, 2);
    try {
      final store = await SharedPreferences.getInstance();
      await store.setInt('$spName/$spKey', instance);
    } catch (_) {
      // 内存态保底：写不进 SP 也让本会话生效（与弹幕配置同理）。
    }
  }
}
