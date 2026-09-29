import 'package:flutter/material.dart';

import '../../services/episode_source_cache.dart';
import '../../services/player_preferences.dart';
import 'quality_icon.dart';

/// 短剧更多面板的**浅色分支**（官方 `ShortSeriesMorePanelDialogV2` 在
/// `play_control_panel_style_v681.style` 未下发或为 0 时的形态，
/// `MorePanelV681.d()==false`：内容布局 `aae.xml` 的 `#FAFAFA` 底 +
/// 16dp 顶圆角，不被 `Q0()` 染成 `#FF1C1C1C`）。
///
/// 行集与官方截图对齐（2026-09-29 用户拍板：全行集，装机后与官方一致；
/// 举报行随后单独拍板移除）：白卡 1 = 倍速、清晰度、清屏播放、离线缓存；
/// 白卡 2 = 投屏、不感兴趣、听视频、弹幕、字体大小。无取消行。可下钻行
/// （离线缓存/投屏/不感兴趣/听视频/字体大小）本客户端没有对应后端链路，
/// 点击关面板并提示「暂未支持」——不是静默死入口。
///
/// 色值（日间皮肤）：面板底 `#FAFAFA`，卡片白底 12dp 圆角；行文字与图标
/// `skin_color_black_light`=#000000；未选中档位
/// `skin_color_gray_40_light`=#66000000；开关开启
/// `skin_color_orange_brand_light`=#FA6725；药丸行是浅灰轨道上排开、
/// 选中档白底黑粗体。
///
/// 浅色支图标是官方 APK 的本地 drawable（jm3 行类 + 弹层级各自绑定），
/// 夜间皮肤官方走 SkinDelegate 翻白，这里按 MaterialApp 亮度做等价切换。
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

  static Color _foreground(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? const Color(0xCCFFFFFF)
      : const Color(0xFF000000);

  static Color _muted(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? const Color(0x66FFFFFF)
      : const Color(0x66000000);

  static Color _handleColor(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? const Color(0x33FFFFFF)
      : const Color(0x1F000000);

  /// 白卡片：官方浅色截图的两块圆角白底（夜间等价翻为亮 overlay）。
  static Color _cardColor(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? const Color(0x14FFFFFF)
      : Colors.white;

  /// 官方药丸行 `ScrollableMultipleOptionsView` 的浅灰轨道。
  static Color _trackColor(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? const Color(0x1FFFFFFF)
      : const Color(0x0F000000);

  TextStyle _labelStyle(BuildContext context) => TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.bold,
    color: _foreground(context),
  );

  @override
  Widget build(BuildContext context) {
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
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _panelCard(context, [
                    _rateRow(context),
                    if (onQualitySelected != null && qualityVariants.length > 1)
                      _qualityRow(context),
                    // 官方行序：清屏行在选项之后（jm3.a 的 p0(!zB0)）。
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
                    _placeholderRow(
                      context,
                      key: 'player-more-light-download',
                      icon: 'more_download',
                      label: '离线缓存',
                    ),
                  ]),
                  const SizedBox(height: 10),
                  _panelCard(context, [
                    _placeholderRow(
                      context,
                      key: 'player-more-light-cast',
                      icon: 'more_cast',
                      label: '投屏',
                    ),
                    _placeholderRow(
                      context,
                      key: 'player-more-light-dislike',
                      icon: 'more_dislike',
                      label: '不感兴趣',
                    ),
                    _placeholderRow(
                      context,
                      key: 'player-more-light-listen',
                      icon: 'more_listen',
                      label: '听视频',
                    ),
                    if (onToggleDanmaku != null)
                      _danmakuRow(context, _foreground(context)),
                    _fontRow(context),
                  ]),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _panelCard(BuildContext context, List<Widget> rows) => Container(
    decoration: BoxDecoration(
      color: _cardColor(context),
      borderRadius: BorderRadius.circular(12),
    ),
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Column(mainAxisSize: MainAxisSize.min, children: rows),
  );

  /// 药丸轨道：浅灰圆角底 + 横向滚动（官方 ScrollableMultipleOptionsView）。
  Widget _pillTrack(BuildContext context, Widget child) => Container(
    height: 36,
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: _trackColor(context),
      borderRadius: BorderRadius.circular(10),
    ),
    child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const ClampingScrollPhysics(),
      child: child,
    ),
  );

  /// 倍速行：图标 + 标签 + 药丸档位（浅色支档位与深色 V2 不同，无 1.75x）。
  Widget _rateRow(BuildContext context) => Padding(
    key: const ValueKey('player-more-light-rate-row'),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    child: SizedBox(
      height: 30,
      child: Row(
        children: [
          _PanelIconLight(name: 'more_rate', color: _foreground(context)),
          const SizedBox(width: 8),
          Text('倍速', style: _labelStyle(context)),
          const SizedBox(width: 16),
          Expanded(
            child: _pillTrack(
              context,
              Row(
                children: [
                  for (final rate in PlayerPreferences.lightPanelPlaybackRates)
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

  /// 清晰度行：多档流药丸直接铺开，选中档即当前流。
  Widget _qualityRow(BuildContext context) => Padding(
    key: const ValueKey('player-more-light-quality-row'),
    padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
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
            child: _pillTrack(
              context,
              Row(
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
        padding: const EdgeInsets.symmetric(horizontal: 12),
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

  /// 官方可下钻行：图标 + 文案 + 尾注/箭头，点击随面板关闭（jm3 行语义）。
  Widget _actionRow(
    BuildContext context, {
    required String key,
    required String icon,
    required String label,
    String? trailing,
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
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: SizedBox(
          key: ValueKey(key),
          height: 48,
          child: Row(
            children: [
              _PanelIconLight(name: icon, color: _foreground(context)),
              const SizedBox(width: 8),
              Text(label, style: _labelStyle(context)),
              const Spacer(),
              if (trailing != null) ...[
                Text(trailing, style: TextStyle(fontSize: 14, color: _muted(context))),
                const SizedBox(width: 4),
              ],
              Icon(Icons.chevron_right, size: 22, color: _muted(context)),
            ],
          ),
        ),
      ),
    ),
  );

  /// 官方有、本客户端无后端链路的行：点击关闭面板并提示，不留静默死入口。
  Widget _placeholderRow(
    BuildContext context, {
    required String key,
    required String icon,
    required String label,
    String? trailing,
  }) {
    void onTap() {
      final messenger = ScaffoldMessenger.of(context);
      Navigator.pop(context);
      messenger.showSnackBar(
        SnackBar(content: Text('$label暂未支持')),
      );
    }

    return _actionRow(
      context,
      key: key,
      icon: icon,
      label: label,
      trailing: trailing,
      onTap: onTap,
    );
  }

  /// 官方字体大小行的尾注是当前档位（截图为「标准」）。
  Widget _fontRow(BuildContext context) => _placeholderRow(
    context,
    key: 'player-more-light-font',
    icon: 'more_font',
    label: '字体大小',
    trailing: '标准',
  );
}

/// 30dp 选项药丸：选中白底黑粗体、未选中灰字（官方浅色截图形态）。
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
              // 选中白底在浅灰轨道上可辨：深色底配色反转。
              color: selected
                  ? (dark ? const Color(0x33FFFFFF) : Colors.white)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(15),
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

/// 浅色行的官方图标资产（jm3 行类 / 弹层级绑定的 drawable），日间染黑、
/// 夜间翻白。
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
