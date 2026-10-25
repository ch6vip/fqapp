/// 短剧弹幕设置：官方 `ay1/v.java` 的四滑杆 + 恢复默认。
///
/// 持久化键与官方同名 SP `danmaku_config`（`impl/danmaku/a.java:38-127`）：
/// - `key_alpha` 默认 255（不透明），设置面板按 20%..100% 换算
///   （`m(p)=(p*255+50)/100`、`a(alpha)=(alpha*100+127)/255`）
/// - `key_speed` 默认 NORMAL=3；5 档 0.5/0.7/1.0/1.25/1.5（`DanmakuSpeed`）
/// - `key_line_count`（竖屏行数）1..4，官方默认来自服务端配置，
///   本地取 4；`key_line_space`（横屏密度）默认 QUARTER=2
/// - `key_text_size` 默认 DEFAULT=3（16sp）；5 档 12/14/16/18/20sp
///   （`DanmakuTextSize.java:114-118`）
///
/// 官方恢复默认 = 五键全 remove 回出厂（`a.java:92-96`）+ Toast
/// 「设置成功」（`eyr`/2131107533）。横竖屏滑杆语义不同：竖屏调行数、
/// 横屏调显示区域密度（`v.java:958-991`）。
library;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'player_side_panel.dart';

/// 官方 `danmaku_config` 五项设置的本地镜像。
class DanmakuSettings {
  const DanmakuSettings({
    this.alpha = 255,
    this.speedTier = 3,
    this.lineCount = 4,
    this.lineSpaceTier = 2,
    this.sizeTier = 3,
    this.transparentBackground = false,
  });

  /// 0..255；面板以 20..100% 呈现。
  final int alpha;

  /// 1..5（慢..快），对应 [speedMultipliers]。
  final int speedTier;

  /// 竖屏轨道行数 1..4。
  final int lineCount;

  /// 横屏显示区域密度 1..4（单行/1/4屏/1/2屏/3/4屏）。
  final int lineSpaceTier;

  /// 字号档位 1..5。
  final int sizeTier;

  /// 弹幕气泡不画 40% 黑底，只留文字。
  final bool transparentBackground;

  /// 官方键之外的本地开关（官方气泡底色写死）。
  static const transparentKey = 'key_bg_transparent';

  static const spName = 'danmaku_config';
  static const speedMultipliers = [0.5, 0.7, 1.0, 1.25, 1.5];
  static const textSizes = [12.0, 14.0, 16.0, 18.0, 20.0];

  /// `DanmakuLineSpace`：SINGLE(1)/QUARTER(2)/HALF(3)/THREE_QUARTER(4)
  /// 对应屏高占比；SINGLE 官方直接取 1 行。
  static const lineSpaceFactors = [1.0, 0.25, 0.5, 0.75];
  static const speedLabels = ['慢', '较慢', '适中', '较快', '快'];
  static const sizeLabels = ['小', '较小', '适中', '较大', '大'];
  static const lineSpaceLabels = ['单行', '1/4屏', '1/2屏', '3/4屏'];

  double get speed => speedMultipliers[speedTier.clamp(1, 5) - 1];
  double get fontSize => textSizes[sizeTier.clamp(1, 5) - 1];

  DanmakuSettings copyWith({
    int? alpha,
    int? speedTier,
    int? lineCount,
    int? lineSpaceTier,
    int? sizeTier,
    bool? transparentBackground,
  }) => DanmakuSettings(
    alpha: alpha ?? this.alpha,
    speedTier: speedTier ?? this.speedTier,
    lineCount: lineCount ?? this.lineCount,
    lineSpaceTier: lineSpaceTier ?? this.lineSpaceTier,
    sizeTier: sizeTier ?? this.sizeTier,
    transparentBackground: transparentBackground ?? this.transparentBackground,
  );

  /// 官方 `a(alpha)=(alpha*100+127)/255`：不透明度百分比。
  int get alphaPercent => (alpha * 100 + 127) ~/ 255;

  /// 官方 `m(p)=(p*255+50)/100`：滑杆百分比 → alpha。
  static int alphaFromPercent(int percent) => (percent * 255 + 50) ~/ 100;

  static Future<DanmakuSettings> load() async {
    final store = await SharedPreferences.getInstance();
    int read(String key, int fallback) =>
        store.getInt('$spName/$key') ?? fallback;
    return DanmakuSettings(
      alpha: read('key_alpha', 255).clamp(0, 255),
      speedTier: read('key_speed', 3).clamp(1, 5),
      lineCount: read('key_line_count', 4).clamp(1, 4),
      lineSpaceTier: read('key_line_space', 2).clamp(1, 4),
      sizeTier: read('key_text_size', 3).clamp(1, 5),
      transparentBackground: store.getBool('$spName/$transparentKey') ?? false,
    );
  }

  static Future<void> save(DanmakuSettings settings) async {
    final store = await SharedPreferences.getInstance();
    await store.setInt('$spName/key_alpha', settings.alpha);
    await store.setInt('$spName/key_speed', settings.speedTier);
    await store.setInt('$spName/key_line_count', settings.lineCount);
    await store.setInt('$spName/key_line_space', settings.lineSpaceTier);
    await store.setInt('$spName/key_text_size', settings.sizeTier);
    await store.setBool(
      '$spName/$transparentKey',
      settings.transparentBackground,
    );
  }
}

/// 弹幕设置面板：四个滑杆 + 恢复默认。几何沿用官方（`v.java:1050-1073`）：
/// 竖屏整宽底部，横屏 372dp 右对齐——由宿主的 bottom sheet 约束实现。
class PlayletDanmakuSettingsPanel extends StatefulWidget {
  const PlayletDanmakuSettingsPanel({
    super.key,
    required this.settings,
    required this.landscape,
    this.onChanged,
    this.onReset,
    this.onClose,
  });

  final DanmakuSettings settings;
  final bool landscape;

  /// 任一滑杆变化即回调（官方经 `UpdateDanmakuConfigEvent` 实时生效）。
  final ValueChanged<DanmakuSettings>? onChanged;
  final VoidCallback? onReset;

  /// ✕ 的行为。默认直接 pop；从视频设置级联进来时传「pop 回视频设置」，
  /// 这样按 ✕ 是退回上一层而不是一路掉回画面。
  final VoidCallback? onClose;

  @override
  State<PlayletDanmakuSettingsPanel> createState() =>
      _PlayletDanmakuSettingsPanelState();
}

class _PlayletDanmakuSettingsPanelState
    extends State<PlayletDanmakuSettingsPanel> {
  late DanmakuSettings _settings = widget.settings;

  void _update(DanmakuSettings settings) {
    setState(() => _settings = settings);
    widget.onChanged?.call(settings);
  }

  @override
  Widget build(BuildContext context) {
    final opacityProgress = _settings.alphaPercent - 20;
    return SafeArea(
      // 竖屏是底部 sheet（顶部由 sheet 自己让开），横屏是右侧全高面板，
      // 需要自己让出顶部安全区。
      top: widget.landscape,
      // 横屏面板贴右缘，左边那条安全区是屏幕另一侧的挖孔，不能让。
      left: false,
      child: Column(
        key: const ValueKey('danmaku-settings-panel'),
        mainAxisSize: MainAxisSize.min,
        children: [
          // 横屏是右侧全高面板（与选集抽屉同宽），没有可拖拽的底部 sheet，
          // 手柄会让人以为是能从底边拉起的弹层；换成同一款标题行。
          if (!widget.landscape)
            SizedBox(
              key: const ValueKey('danmaku-settings-drag-handle'),
              height: 20,
              width: double.infinity,
              child: Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: const Color(0x33FFFFFF),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            )
          else
            PlayerSidePanelHeader(
              title: '弹幕设置',
              onClose: widget.onClose ?? () => Navigator.pop(context),
            ),
          // 横屏面板只有一块屏高（真机约 361dp），64dp 标题 + 六个设置项
          // 再加底部安全区就顶出去了——Column 溢出会画黄黑警示条。收进
          // `Flexible` 的滚动区：竖屏 sheet 仍按内容高度收紧，横屏超出时
          // 可以滚，不再溢出。
          Flexible(
            child: SingleChildScrollView(
              padding: EdgeInsets.only(
                bottom: MediaQuery.paddingOf(context).bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _sliderRow(
                    key: 'danmaku-settings-opacity',
                    label: '不透明度',
                    value: opacityProgress.clamp(0, 80).toDouble(),
                    max: 80,
                    label2: '${_settings.alphaPercent}%',
                    onChanged: (v) => _update(
                      _settings.copyWith(
                        alpha: DanmakuSettings.alphaFromPercent(v.round() + 20),
                      ),
                    ),
                  ),
                  _sliderRow(
                    key: 'danmaku-settings-speed',
                    label: '弹幕速度',
                    value: (_settings.speedTier - 1).toDouble(),
                    max: 4,
                    divisions: 4,
                    label2:
                        DanmakuSettings.speedLabels[_settings.speedTier - 1],
                    onChanged: (v) =>
                        _update(_settings.copyWith(speedTier: v.round() + 1)),
                  ),
                  _sliderRow(
                    key: 'danmaku-settings-region',
                    label: '显示区域',
                    value: _regionValue,
                    max: 3,
                    divisions: 3,
                    label2: _regionLabel,
                    onChanged: (v) => _update(_withRegion(v.round() + 1)),
                  ),
                  _sliderRow(
                    key: 'danmaku-settings-size',
                    label: '字号',
                    value: (_settings.sizeTier - 1).toDouble(),
                    max: 4,
                    divisions: 4,
                    label2: DanmakuSettings.sizeLabels[_settings.sizeTier - 1],
                    onChanged: (v) =>
                        _update(_settings.copyWith(sizeTier: v.round() + 1)),
                  ),
                  _backgroundRow(),
                  Semantics(
                    key: const ValueKey('danmaku-settings-reset-row'),
                    button: true,
                    child: InkWell(
                      key: const ValueKey('danmaku-settings-reset'),
                      onTap: () {
                        // 官方恢复默认回五键出厂值并 Toast「设置成功」。
                        _update(const DanmakuSettings());
                        widget.onReset?.call();
                      },
                      child: Container(
                        alignment: Alignment.center,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        width: double.infinity,
                        child: const Text('恢复默认', style: _labelStyle),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  double get _regionValue =>
      (widget.landscape ? _settings.lineSpaceTier : _settings.lineCount) - 1.0;
  String get _regionLabel => widget.landscape
      ? DanmakuSettings.lineSpaceLabels[_settings.lineSpaceTier - 1]
      : '${_settings.lineCount}行';

  DanmakuSettings _withRegion(int tier) => _settings.copyWith(
    lineCount: widget.landscape ? null : tier,
    lineSpaceTier: widget.landscape ? tier : null,
  );

  /// 弹幕背景透明：整行可点，Switch 自身不重复响应（与更多面板的
  /// 开关行同一语义）。
  Widget _backgroundRow() => GestureDetector(
    key: const ValueKey('danmaku-settings-transparent-row'),
    behavior: HitTestBehavior.opaque,
    onTap: () => _update(
      _settings.copyWith(
        transparentBackground: !_settings.transparentBackground,
      ),
    ),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 10, 2),
      child: Row(
        children: [
          const Expanded(child: Text('弹幕背景透明', style: _labelStyle)),
          Switch(
            key: const ValueKey('danmaku-settings-transparent'),
            value: _settings.transparentBackground,
            onChanged: (value) =>
                _update(_settings.copyWith(transparentBackground: value)),
          ),
        ],
      ),
    ),
  );

  Widget _sliderRow({
    required String key,
    required String label,
    required double value,
    required double max,
    int? divisions,
    required String label2,
    required ValueChanged<double> onChanged,
  }) => Padding(
    key: ValueKey(key),
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
    child: Row(
      children: [
        SizedBox(width: 76, child: Text(label, style: _labelStyle)),
        Expanded(
          child: Slider(
            value: value.clamp(0, max),
            max: max,
            divisions: divisions,
            label: label2,
            activeColor: const Color(0xFFFA6725),
            inactiveColor: const Color(0x33FFFFFF),
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 52,
          child: Text(label2, textAlign: TextAlign.end, style: _labelStyle),
        ),
      ],
    ),
  );
}

const _labelStyle = TextStyle(fontSize: 14, color: Colors.white);
