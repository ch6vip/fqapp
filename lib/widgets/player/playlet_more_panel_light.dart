import 'package:flutter/material.dart';

import '../../services/episode_source_cache.dart';
import '../../services/player_preferences.dart';
import 'quality_icon.dart';

/// 短剧更多面板的**浅色分支**（官方 `ShortSeriesMorePanelDialogV2` 在
/// `play_control_panel_style_v681.style` 未下发或为 0 时的形态，
/// `MorePanelV681.d()==false`：保留内容布局 `aae.xml` 的 `#FAFAFA` 底 +
/// 16dp 顶圆角，不被 `Q0()` 染成 `#FF1C1C1C`）。
///
/// 行集按用户设备截图（该分支的真实渲染）：倍速、清晰度（药丸选项，
/// `ScrollableMultipleOptionsView` + `useNewOptionItemStyle` 的 30dp 药丸）、
/// 清屏播放、弹幕开关；**无取消行**。官方同分支还有 投屏/离线缓存/不感兴趣/
/// 听视频/字体大小/举报（`oi3/k.o()` 按各自配置门补齐），本客户端没有对应
/// 后端链路，按「不留死入口」的取舍不显示——追样式不追死行。
///
/// 色值（日间皮肤）：行文字与图标 `skin_color_black_light`=#000000，
/// 未选中档位 `skin_color_gray_40_light`=#66000000，开关开启
/// `skin_color_orange_brand_light`=#FA6725；选中药丸为白底描边（截图）。
///
/// 选档即返回：官方药丸点击立即生效（`jj3/i.e` → `playerController.e()`），
/// 与深色分支「先动画再回传」不同。倍速回传 double，清晰度回传
/// [EpisodeVariant]，宿主按类型分派。
class PlayletMorePanelLight extends StatelessWidget {
  const PlayletMorePanelLight({
    super.key,
    required this.rate,
    this.qualityVariants = const [],
    this.currentQualityUrl,
    this.onQualitySelected,
    this.clearScreen = false,
    this.onToggleClearScreen,
    this.danmakuEnabled = false,
    this.onToggleDanmaku,
  });

  final double rate;

  /// 多档流在场才显示清晰度行（与深色分支同门，官方 `oi3/k.P()`）。
  final List<EpisodeVariant> qualityVariants;
  final String? currentQualityUrl;
  final ValueChanged<EpisodeVariant>? onQualitySelected;

  final bool clearScreen;
  final VoidCallback? onToggleClearScreen;

  final bool danmakuEnabled;
  final VoidCallback? onToggleDanmaku;

  /// 日间肤色的行前景色。官方走 SkinDelegate（夜间翻白），本面板跟随
  /// MaterialApp 亮度做等价切换。
  static Color _foreground(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? const Color(0xCCFFFFFF)
      : const Color(0xFF000000);

  static Color _handleColor(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? const Color(0x33FFFFFF)
      : const Color(0x1F000000);

  TextStyle _labelStyle(BuildContext context) => TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.bold,
    color: _foreground(context),
  );

  @override
  Widget build(BuildContext context) {
    final foreground = _foreground(context);
    return SafeArea(
      top: false,
      child: Column(
        key: const ValueKey('player-more-light-panel'),
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            key: const ValueKey('player-more-light-drag-handle'),
            height: 20,
            width: double.infinity,
            child: Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: _handleColor(context),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _rateRow(context),
                  // 官方 r() 行序：清屏行在选项之后（jm3.a 的 p0(!zB0)）。
                  if (onToggleClearScreen != null)
                    _actionRow(
                      context,
                      key: 'player-more-light-clear',
                      icon: 'more_clear',
                      label: clearScreen ? '退出清屏' : '清屏播放',
                      onTap: () {
                        onToggleClearScreen!();
                        Navigator.pop(context);
                      },
                    ),
                  if (onQualitySelected != null &&
                      qualityVariants.length > 1)
                    _qualityRow(context),
                  if (onToggleDanmaku != null)
                    _danmakuRow(context, foreground),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 倍速行：图标 + 标签 + 药丸档位（官方 30dp 新药丸样式）。
  Widget _rateRow(BuildContext context) => Padding(
    key: const ValueKey('player-more-light-rate-row'),
    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
    child: SizedBox(
      height: 30,
      child: Row(
        children: [
          _PanelIconLight(name: 'more_rate', color: _foreground(context)),
          const SizedBox(width: 8),
          Text('倍速', style: _labelStyle(context)),
          const SizedBox(width: 16),
          Expanded(
            child: SingleChildScrollView(
              key: const ValueKey('player-more-light-rate-scroll'),
              scrollDirection: Axis.horizontal,
              physics: const ClampingScrollPhysics(),
              child: Row(
                children: [
                  for (final rate in PlayerPreferences.playbackRates)
                    _OptionPill(
                      key: ValueKey('player-more-light-rate-$rate'),
                      label:
                          '${rate == rate.roundToDouble() ? rate.toInt() : rate}x',
                      selected: rate == this.rate,
                      onTap: () => Navigator.pop(context, rate),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );

  /// 清晰度行：药丸直接铺开（官方浅色分支同形态），选中档即当前流。
  Widget _qualityRow(BuildContext context) => Padding(
    key: const ValueKey('player-more-light-quality-row'),
    padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
    child: SizedBox(
      height: 30,
      child: Row(
        children: [
          SizedBox(
            width: 24,
            height: 24,
            child: CustomPaint(
              painter: QualityIconPainter(color: _foreground(context)),
            ),
          ),
          const SizedBox(width: 8),
          Text('清晰度', style: _labelStyle(context)),
          const SizedBox(width: 16),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const ClampingScrollPhysics(),
              child: Row(
                children: [
                  for (final (index, variant) in qualityVariants.indexed)
                    _OptionPill(
                      key: ValueKey('player-more-light-quality-$index'),
                      label: variant.name,
                      selected: variant.url == currentQualityUrl,
                      onTap: () => Navigator.pop(context, variant),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _danmakuRow(BuildContext context, Color foreground) => Semantics(
    key: const ValueKey('player-more-light-danmaku-row'),
    label: '弹幕',
    toggled: danmakuEnabled,
    onTap: onToggleDanmaku,
    excludeSemantics: true,
    child: InkWell(
      onTap: onToggleDanmaku,
      excludeFromSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: SizedBox(
          height: 48,
          child: Row(
            children: [
              _PanelIconLight(name: 'more_danmaku', color: foreground),
              const SizedBox(width: 8),
              Expanded(child: Text('弹幕', style: _labelStyle(context))),
              const SizedBox(width: 12),
              _LightSwitch(value: danmakuEnabled),
            ],
          ),
        ),
      ),
    ),
  );

  /// 官方行：图标 + 文案整行点击（jm3 行语义），点击后随面板关闭。
  Widget _actionRow(
    BuildContext context, {
    required String key,
    required String icon,
    required String label,
    required VoidCallback onTap,
  }) => Semantics(
    key: ValueKey('$key-row'),
    label: label,
    button: true,
    onTap: onTap,
    excludeSemantics: true,
    child: InkWell(
      onTap: onTap,
      excludeFromSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: SizedBox(
          key: ValueKey(key),
          height: 48,
          child: Row(
            children: [
              _PanelIconLight(name: icon, color: _foreground(context)),
              const SizedBox(width: 8),
              Text(label, style: _labelStyle(context)),
            ],
          ),
        ),
      ),
    ),
  );
}

/// 30dp 选项药丸：选中白底描边 + 黑色粗体，未选中灰字（官方浅色截图形态）。
class _OptionPill extends StatelessWidget {
  const _OptionPill({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final foreground = dark ? const Color(0xCCFFFFFF) : const Color(0xFF000000);
    final muted = dark ? const Color(0x66FFFFFF) : const Color(0x66000000);
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Semantics(
        label: '$label${selected ? '（当前）' : ''}',
        button: true,
        selected: selected,
        onTap: onTap,
        excludeSemantics: true,
        child: InkWell(
          onTap: onTap,
          excludeFromSemantics: true,
          borderRadius: BorderRadius.circular(15),
          child: Container(
            height: 30,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              // 选中白底描边只在浅色底上可辨：深色底配色反转。
              color: selected
                  ? (dark ? const Color(0x33FFFFFF) : Colors.white)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(15),
              border: Border.all(
                color: selected
                    ? (dark ? const Color(0x66FFFFFF) : const Color(0x1F000000))
                    : Colors.transparent,
              ),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                color: selected ? foreground : muted,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 官方浅色分支的开关形态（`SwitchButtonV2` 31×18dp）：开启用品牌橙
/// `skin_color_orange_brand_light`=#FA6725，关闭灰底。整行承载点击，
/// 开关本身不注册回调（与深色分支同一语义）。
class _LightSwitch extends StatelessWidget {
  const _LightSwitch({required this.value});

  final bool value;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      width: 31,
      height: 18,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: value
            ? const Color(0xFFFA6725)
            : (dark ? const Color(0x33FFFFFF) : const Color(0x1F000000)),
        borderRadius: BorderRadius.circular(9),
      ),
      child: AnimatedAlign(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
        alignment: value ? Alignment.centerRight : Alignment.centerLeft,
        child: const DecoratedBox(
          decoration: BoxDecoration(color: Colors.white, shape: BoxShape.circle),
          child: SizedBox.square(dimension: 14),
        ),
      ),
    );
  }
}

/// 浅色行的官方图标资产（与深色面板同一批 webp），日间染黑、夜间翻白。
class _PanelIconLight extends StatelessWidget {
  const _PanelIconLight({required this.name, required this.color});

  final String name;
  final Color color;

  @override
  Widget build(BuildContext context) => Image.asset(
    'assets/images/drama/$name.webp',
    width: 24,
    height: 24,
    color: color,
    excludeFromSemantics: true,
  );
}
