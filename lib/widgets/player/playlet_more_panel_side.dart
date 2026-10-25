import 'package:flutter/material.dart';

import '../../services/short_series_font_scale.dart';
import 'playlet_danmaku_settings.dart';
import 'playlet_font_scale_sheet.dart';
import 'player_side_panel.dart';
import 'player_toast.dart';

/// 横屏视频设置的一整串面板：视频设置 ↔ 弹幕设置 / 字号。
///
/// 倍速与清晰度不在这串里：底条右下角已经显示当前档，点它直接开对应的
/// 档位面板（chrome `_showLandscapeRateSheet` / `_showLandscapeQualitySheet`）。
///
/// 三块面板共用**同一条**右侧路由，切层只是替换内容（不重新滑入，也不
/// 闪一帧画面）。二级面板的 ✕ 回到视频设置。开关状态放在这一层：从二级
/// 面板退回来时开关不会跳回打开前的样子。
class PlayletSideSettingsFlow extends StatefulWidget {
  const PlayletSideSettingsFlow({
    super.key,
    this.clearScreen = false,
    this.onToggleClearScreen,
    this.danmakuEnabled = false,
    this.onToggleDanmaku,
    this.danmakuSettings,
    this.onDanmakuSettingsChanged,
    this.onDanmakuReset,
    this.fontScaleLabel,
    this.fontScale = false,
    this.onFontScaleSelected,
    this.fillScreen = false,
    this.onFillScreenChanged,
    this.defaultMute = false,
    this.onDefaultMuteChanged,
    this.onOpenListenMode,
    this.onOpenOfflineCache,
  });

  final bool clearScreen;
  final VoidCallback? onToggleClearScreen;

  final bool danmakuEnabled;
  final VoidCallback? onToggleDanmaku;

  /// 非空才给「弹幕设置」行（后端没有设置面板时整行不出现）。
  final DanmakuSettings? danmakuSettings;
  final ValueChanged<DanmakuSettings>? onDanmakuSettingsChanged;

  /// 「恢复默认」后的提示（官方 Toast「设置成功」）。
  final VoidCallback? onDanmakuReset;

  /// 行尾字号档（官方 `jk3/b.f()`）。
  final String? fontScaleLabel;

  /// 字号出口可用时才出现「字体大小」行。
  final bool fontScale;
  final VoidCallback? onFontScaleSelected;

  final bool fillScreen;
  final ValueChanged<bool>? onFillScreenChanged;

  final bool defaultMute;
  final ValueChanged<bool>? onDefaultMuteChanged;

  final VoidCallback? onOpenListenMode;
  final VoidCallback? onOpenOfflineCache;

  @override
  State<PlayletSideSettingsFlow> createState() =>
      _PlayletSideSettingsFlowState();
}

class _PlayletSideSettingsFlowState extends State<PlayletSideSettingsFlow> {
  PlayerSidePanelRoute _route = PlayerSidePanelRoute.more;
  late bool _danmaku = widget.danmakuEnabled;
  late bool _fill = widget.fillScreen;
  late bool _mute = widget.defaultMute;
  late DanmakuSettings _settings =
      widget.danmakuSettings ?? const DanmakuSettings();

  /// 字号行尾的档名。字号档是进程级 static（`ShortSeriesFontScale`，不带
  /// 通知），宿主 `setState` 也重建不到 overlay 里的这条路由，所以在这里
  /// 自己持一份：选档后立刻刷新，✕ 退回视频设置时行尾不会还写着旧档。
  late String? _fontScaleLabel = widget.fontScaleLabel;

  void _backToMore() => setState(() => _route = PlayerSidePanelRoute.more);

  void _step(PlayerSidePanelRoute route) => setState(() => _route = route);

  /// 先收起整串、再执行面板外的动作（清屏 / 听视频 / 离线缓存）：
  /// 与底部弹层的「点行即关面板」同语义。
  void _closeThen(VoidCallback action) {
    Navigator.pop(context);
    action();
  }

  @override
  Widget build(BuildContext context) => switch (_route) {
    PlayerSidePanelRoute.more => PlayletMorePanelSide(
      clearScreen: widget.clearScreen,
      onToggleClearScreen: widget.onToggleClearScreen == null
          ? null
          : () => _closeThen(widget.onToggleClearScreen!),
      danmakuEnabled: _danmaku,
      onToggleDanmaku: widget.onToggleDanmaku == null
          ? null
          : () {
              setState(() => _danmaku = !_danmaku);
              widget.onToggleDanmaku!();
            },
      danmakuSettings: widget.danmakuSettings != null,
      fontScaleLabel: _fontScaleLabel,
      fontScale: widget.fontScale,
      fillScreen: _fill,
      onFillScreenChanged: widget.onFillScreenChanged == null
          ? null
          : () {
              setState(() => _fill = !_fill);
              widget.onFillScreenChanged!(_fill);
            },
      defaultMute: _mute,
      onDefaultMuteChanged: widget.onDefaultMuteChanged == null
          ? null
          : () {
              setState(() => _mute = !_mute);
              widget.onDefaultMuteChanged!(_mute);
            },
      onOpenListenMode: widget.onOpenListenMode == null
          ? null
          : () => _closeThen(widget.onOpenListenMode!),
      onOpenOfflineCache: widget.onOpenOfflineCache == null
          ? null
          : () => _closeThen(widget.onOpenOfflineCache!),
      onStep: _step,
    ),
    PlayerSidePanelRoute.danmakuSettings => PlayletDanmakuSettingsPanel(
      key: const ValueKey('player-side-danmaku-settings'),
      settings: _settings,
      landscape: true,
      onClose: _backToMore,
      onChanged: (settings) {
        setState(() => _settings = settings);
        widget.onDanmakuSettingsChanged?.call(settings);
      },
      onReset: widget.onDanmakuReset,
    ),
    PlayerSidePanelRoute.fontScale => PlayletFontScaleSidePanel(
      key: const ValueKey('player-side-font-scale'),
      onBack: _backToMore,
      onSelected: () {
        // 档位在栈内就生效：同步刷新行尾文案，再通知宿主重排自己的树。
        setState(() => _fontScaleLabel = ShortSeriesFontScale.label);
        widget.onFontScaleSelected?.call();
      },
    ),
  };
}

/// 横屏「视频设置」的列表本体：标题行 + 三列宫格 + 两条下钻行。
///
/// 倍速与清晰度不在这里：底条右下角已经显示当前档，点它直接开对应的档位
/// 面板，视频设置再放一遍就是同一件事两个入口。剩下的开关与「点了就执行」
/// 的入口压成宫格，一屏（真机横屏约 361dp 高）放得下，不用滚动去找弹幕和
/// 字号；只有会进二级面板的两行仍用整行，行尾带当前值。
///
/// 开关值与字号档由 [PlayletSideSettingsFlow] 持有，这里只渲染与转发，
/// 切层往返后开关不会跳回原样。
class PlayletMorePanelSide extends StatelessWidget {
  const PlayletMorePanelSide({
    super.key,
    this.clearScreen = false,
    this.onToggleClearScreen,
    this.danmakuEnabled = false,
    this.onToggleDanmaku,
    this.danmakuSettings = false,
    this.fontScaleLabel,
    this.fontScale = false,
    this.fillScreen = false,
    this.onFillScreenChanged,
    this.defaultMute = false,
    this.onDefaultMuteChanged,
    this.onOpenListenMode,
    this.onOpenOfflineCache,
    required this.onStep,
  });

  final bool clearScreen;
  final VoidCallback? onToggleClearScreen;

  final bool danmakuEnabled;
  final VoidCallback? onToggleDanmaku;

  final bool danmakuSettings;

  final String? fontScaleLabel;
  final bool fontScale;

  final bool fillScreen;
  final VoidCallback? onFillScreenChanged;

  final bool defaultMute;
  final VoidCallback? onDefaultMuteChanged;

  final VoidCallback? onOpenListenMode;
  final VoidCallback? onOpenOfflineCache;

  /// 切到二级面板（弹幕设置 / 字号）。
  final ValueChanged<PlayerSidePanelRoute> onStep;

  @override
  Widget build(BuildContext context) {
    final insets = MediaQuery.paddingOf(context);
    final tiles = <Widget>[
      // 开关块在前：宫格里「当前开着哪几项」比入口更容易一眼扫到。
      if (onFillScreenChanged != null)
        PlayerSidePanelTile(
          tileKey: 'player-more-fill',
          label: '画面撑满',
          icon: 'fill',
          active: fillScreen,
          stateKey: 'player-more-fill-switch',
          onTap: onFillScreenChanged,
        ),
      if (onDefaultMuteChanged != null)
        PlayerSidePanelTile(
          tileKey: 'player-more-mute',
          label: '默认静音',
          icon: 'mute',
          active: defaultMute,
          stateKey: 'player-more-mute-switch',
          onTap: onDefaultMuteChanged,
        ),
      if (onToggleDanmaku != null)
        PlayerSidePanelTile(
          tileKey: 'player-more-danmaku',
          label: '弹幕',
          icon: 'danmaku',
          active: danmakuEnabled,
          stateKey: 'player-more-danmaku-switch',
          onTap: onToggleDanmaku,
        ),
      if (onToggleClearScreen != null)
        PlayerSidePanelTile(
          tileKey: 'player-more-clear',
          label: clearScreen ? '退出清屏' : '清屏播放',
          icon: clearScreen ? 'clear_exit' : 'clear',
          onTap: onToggleClearScreen,
        ),
      if (onOpenListenMode != null)
        PlayerSidePanelTile(
          tileKey: 'player-more-listen',
          label: '听视频',
          icon: 'listen',
          onTap: onOpenListenMode,
        ),
      // 离线缓存暂无后端链路，点了关面板并提示——不留静默死入口。
      PlayerSidePanelTile(
        tileKey: 'player-more-download',
        label: '离线缓存',
        icon: 'download',
        onTap:
            onOpenOfflineCache ??
            () {
              PlayerToast.show(context, '离线缓存暂未支持');
              Navigator.pop(context);
            },
      ),
    ];
    final entryRows = <Widget>[
      if (danmakuSettings)
        PlayerSidePanelRow(
          rowKey: 'player-more-danmaku_settings',
          label: '弹幕设置',
          icon: 'danmaku_settings',
          onTap: () => onStep(PlayerSidePanelRoute.danmakuSettings),
        ),
      if (fontScale)
        PlayerSidePanelRow(
          rowKey: 'player-more-font',
          label: '字体大小',
          icon: 'font',
          value: fontScaleLabel,
          onTap: () => onStep(PlayerSidePanelRoute.fontScale),
        ),
    ];
    return SafeArea(
      // 面板贴右缘：左边那条安全区属于屏幕另一侧的挖孔，让开会把整列右推。
      left: false,
      child: Column(
        key: const ValueKey('player-more-panel'),
        children: [
          PlayerSidePanelHeader(
            title: '视频设置',
            onClose: () => Navigator.pop(context),
          ),
          Expanded(
            child: ListView(
              key: const ValueKey('player-more-scroll'),
              padding: EdgeInsets.fromLTRB(12, 0, 12, 8 + insets.bottom),
              children: [
                LayoutBuilder(
                  builder: (context, constraints) {
                    const gap = 8.0;
                    final width = (constraints.maxWidth - gap * 2) / 3;
                    return Wrap(
                      spacing: gap,
                      runSpacing: gap,
                      children: [
                        // 块自己长高（最小 68dp）：大字号下标签换行不溢出。
                        for (final tile in tiles)
                          SizedBox(width: width, child: tile),
                      ],
                    );
                  },
                ),
                if (entryRows.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  PlayerSidePanelCard(children: entryRows),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
