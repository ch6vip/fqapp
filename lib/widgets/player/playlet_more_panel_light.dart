import 'package:flutter/material.dart';

import 'player_toast.dart';
import 'quality_icon.dart';

/// 短剧更多面板的**浅色分支**（官方 `ShortSeriesMorePanelDialogV2` 在
/// `play_control_panel_style_v681.style` 未下发或为 0 时的形态，
/// `MorePanelV681.d()==false`：内容布局 `aae.xml` 的 `#FAFAFA` 底 + 16dp
/// 顶圆角，不被 `Q0()` 染成 `#FF1C1C1C`）。
///
/// 放开关、下钻入口，以及**可选的**倍速/清晰度入口行（`rateLabel` /
/// `onOpenRate` 等）：底栏已有当前档时宿主不传，面板里就不出现这两项；
/// `catalog` 形态竖屏、feed 卡片、通用播放器才由宿主传入、点开档位弹层。
/// 白卡 1 = 清屏播放、离线缓存；白卡 2 = 听视频、弹幕、字体大小。
/// 举报/投屏/不感兴趣三行明确不做。
///
/// 色值（日间皮肤）：面板底 `#FAFAFA`，卡片白底 12dp 圆角；行文字与图标
/// `skin_color_black_light`=#000000；开关开启
/// `skin_color_orange_brand_light`=#FA6725。
///
/// 浅色支图标是官方 APK 的本地 drawable（jm3 行类 + 弹层级各自绑定），
/// 夜间皮肤官方走 SkinDelegate 翻白，这里按 MaterialApp 亮度做等价切换。
class PlayletMorePanelLight extends StatelessWidget {
  const PlayletMorePanelLight({
    super.key,
    this.clearScreen = false,
    this.onToggleClearScreen,
    this.danmakuEnabled = false,
    this.onToggleDanmaku,
    this.onOpenDanmakuSettings,
    this.fontScaleLabel,
    this.onOpenFontSettings,
    this.onOpenListenMode,
    this.onOpenOfflineCache,
    this.rateLabel,
    this.onOpenRate,
    this.qualityLabel,
    this.onOpenQuality,
  });

  final bool clearScreen;
  final VoidCallback? onToggleClearScreen;

  final bool danmakuEnabled;
  final VoidCallback? onToggleDanmaku;

  /// 「弹幕设置」入口（官方 `jm3.e`，label `a2v`，在弹幕开关之后）。
  /// null 时整行不出现（深色分支同门）。
  final VoidCallback? onOpenDanmakuSettings;

  /// 官方 `jm3.t0`：行尾展示当前字号档（`jk3/b.f()`）。null 时不显示档位。
  final String? fontScaleLabel;

  /// 官方 `jm3.t0.m()`：点击关闭面板并打开字号弹层（`nm3.e`）。null 时
  /// 整行不出现（feed 长按面板未接字号）。
  final VoidCallback? onOpenFontSettings;

  /// 官方 `jm3.d0.y()`：点击关闭面板并打开听书模式页。null 时整行不出现。
  final VoidCallback? onOpenListenMode;

  /// 官方 `jm3.u`：点击关闭面板并打开选集下载弹窗。null 时退化为
  /// 「暂未支持」占位（feed 长按面板未接下载）。
  final VoidCallback? onOpenOfflineCache;

  /// 倍速/清晰度的**入口行**（行尾当前档，点击交给宿主开档位弹层）。
  ///
  /// 播放页不放这两行：底栏右下角已经写着当前档，点它直接开档位弹层。
  /// feed 卡片没有那条底栏，长按面板是它唯一的换档入口，所以宿主在这里传
  /// label + 回调（回调非空才出行；清晰度只在多档流在场时传）。
  final String? rateLabel;
  final VoidCallback? onOpenRate;
  final String? qualityLabel;
  final VoidCallback? onOpenQuality;

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

  TextStyle _labelStyle(BuildContext context) => TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.bold,
    color: _foreground(context),
  );

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      // 底部弹层通栏宽：左边那条竖握时的挖孔不该把整列内容右推。
      left: false,
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
                    // 倍速/清晰度入口行（feed 专用：卡片没有底栏当前档可点，
                    // 播放页的两项走底栏直连的档位弹层）。
                    if (onOpenRate != null)
                      _actionRow(
                        context,
                        key: 'player-more-light-rate',
                        icon: 'more_rate',
                        label: '倍速',
                        trailing: rateLabel,
                        onTap: () {
                          Navigator.pop(context);
                          onOpenRate!();
                        },
                      ),
                    if (onOpenQuality != null)
                      _actionRow(
                        context,
                        key: 'player-more-light-quality',
                        leading: SizedBox(
                          width: 24,
                          height: 24,
                          child: CustomPaint(
                            painter: QualityIconPainter(
                              color: _foreground(context),
                            ),
                          ),
                        ),
                        label: '清晰度',
                        trailing: qualityLabel,
                        onTap: () {
                          Navigator.pop(context);
                          onOpenQuality!();
                        },
                      ),
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
                    if (onOpenOfflineCache != null)
                      _actionRow(
                        context,
                        key: 'player-more-light-download',
                        icon: 'more_download',
                        label: '离线缓存',
                        onTap: () {
                          Navigator.pop(context);
                          onOpenOfflineCache!();
                        },
                      )
                    else
                      _placeholderRow(
                        context,
                        key: 'player-more-light-download',
                        icon: 'more_download',
                        label: '离线缓存',
                      ),
                  ]),
                  const SizedBox(height: 10),
                  _panelCard(context, [
                    if (onOpenListenMode != null)
                      _actionRow(
                        context,
                        key: 'player-more-light-listen',
                        icon: 'more_listen',
                        label: '听视频',
                        onTap: () {
                          Navigator.pop(context);
                          onOpenListenMode!();
                        },
                      ),
                    if (onToggleDanmaku != null)
                      _SwitchRow(
                        rowKey: 'player-more-light-danmaku',
                        icon: 'more_danmaku',
                        label: '弹幕',
                        toggled: danmakuEnabled,
                        onToggle: onToggleDanmaku!,
                        foreground: _foreground(context),
                        labelStyle: _labelStyle(context),
                      ),
                    if (onOpenDanmakuSettings != null)
                      _actionRow(
                        context,
                        key: 'player-more-light-danmaku-settings',
                        icon: 'more_danmaku_settings',
                        label: '弹幕设置',
                        onTap: () {
                          Navigator.pop(context);
                          onOpenDanmakuSettings!();
                        },
                      ),
                    if (onOpenFontSettings != null)
                      _actionRow(
                        context,
                        key: 'player-more-light-font',
                        icon: 'more_font',
                        label: '字体大小',
                        trailing: fontScaleLabel,
                        onTap: () {
                          Navigator.pop(context);
                          onOpenFontSettings!();
                        },
                      ),
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

  /// 官方可下钻行：图标 + 文案 + 尾注/箭头，点击随面板关闭（jm3 行语义）。
  ///
  /// 图标默认取 `assets/images/drama/<icon>.webp`；没有对应资产的（清晰度
  /// 用的是自绘图标）传 [leading]。
  Widget _actionRow(
    BuildContext context, {
    required String key,
    String? icon,
    Widget? leading,
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
              if (leading != null) ...[
                SizedBox(width: 24, height: 24, child: leading),
                const SizedBox(width: 8),
              ] else if (icon != null) ...[
                _PanelIconLight(name: icon, color: _foreground(context)),
                const SizedBox(width: 8),
              ],
              Text(label, style: _labelStyle(context)),
              const Spacer(),
              if (trailing != null) ...[
                Text(
                  trailing,
                  style: TextStyle(fontSize: 14, color: _muted(context)),
                ),
                const SizedBox(width: 4),
              ],
              Icon(Icons.chevron_right, size: 22, color: _muted(context)),
            ],
          ),
        ),
      ),
    ),
  );

  /// 官方有、本客户端暂无后端链路的行（当前仅剩离线缓存）：点击关闭面板
  /// 并提示，不留静默死入口。听视频/字体大小已是真功能；举报/投屏/
  /// 不感兴趣是明确不做（docs/validation/short-drama-light-panel-row-cuts）。
  Widget _placeholderRow(
    BuildContext context, {
    required String key,
    required String icon,
    required String label,
    String? trailing,
  }) {
    void onTap() {
      // 面板随后就关，提示先挂到根 Overlay 上：换成紧凑胶囊 Toast 后
      // 不再依赖 ScaffoldMessenger 的排队与时长。
      PlayerToast.show(context, '$label暂未支持');
      Navigator.pop(context);
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
}

/// 弹幕开关行：自带本地 state（深色面板同款模式）。
///
/// bottom sheet 不跟随父级 setState 重建，开关若只渲染传入的快照，
/// 点完会停在旧状态、重开面板才刷新；本地 state 让开关动画立刻跟随。
/// 面板其余行都随面板关闭（清屏/字号/下钻行），不受此问题影响。
class _SwitchRow extends StatefulWidget {
  const _SwitchRow({
    required this.rowKey,
    required this.icon,
    required this.label,
    required this.toggled,
    required this.onToggle,
    required this.foreground,
    required this.labelStyle,
  });

  /// 行 key 前缀；渲染出的行 key 是 `<rowKey>-row`（与既有弹幕行保持一致）。
  final String rowKey;
  final String icon;
  final String label;
  final bool toggled;
  final VoidCallback onToggle;
  final Color foreground;
  final TextStyle labelStyle;

  @override
  State<_SwitchRow> createState() => _SwitchRowState();
}

class _SwitchRowState extends State<_SwitchRow> {
  late bool _enabled = widget.toggled;

  @override
  void didUpdateWidget(_SwitchRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 面板打开期间父级已翻转该开关且 sheet 子树原地重建时，旧 State 仍持旧值
    // 会导致之后每次点击与父级持续反向；跟随父级同步。
    if (oldWidget.toggled != widget.toggled) {
      _enabled = widget.toggled;
    }
  }

  @override
  Widget build(BuildContext context) => Semantics(
    key: ValueKey('${widget.rowKey}-row'),
    label: widget.label,
    toggled: _enabled,
    onTap: _toggle,
    excludeSemantics: true,
    child: InkWell(
      onTap: _toggle,
      excludeFromSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: SizedBox(
          height: 48,
          child: Row(
            children: [
              _PanelIconLight(name: widget.icon, color: widget.foreground),
              const SizedBox(width: 8),
              Expanded(child: Text(widget.label, style: widget.labelStyle)),
              const SizedBox(width: 12),
              _LightSwitch(value: _enabled),
            ],
          ),
        ),
      ),
    ),
  );

  void _toggle() {
    setState(() => _enabled = !_enabled);
    widget.onToggle();
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
          decoration: BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
          ),
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
