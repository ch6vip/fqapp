import 'package:flutter/material.dart';

// Note: 官方分支、档位动画和关闭边界见
// .agents/notes/implemented/feature/2026-09-26-playlet-more-panel.md
/// 短剧「视频设置」的深色 V2 形态（底部 sheet）。
///
/// 放开关、下钻入口，以及**可选的**倍速/清晰度入口行（`rateLabel` /
/// `onOpenRate` 等）：底栏或分屏紧凑条已经显示当前档时宿主不传，面板里就
/// 不出现这两项——同一件事不留两个入口；`catalog` 形态竖屏、feed 卡片、
/// 通用播放器没有那条底栏，才由宿主传 label + 回调，点行收起面板后开档位
/// 弹层。开关类行始终在。
class PlayletMorePanel extends StatefulWidget {
  const PlayletMorePanel({
    super.key,
    required this.fillScreen,
    this.onFillScreenChanged,
    required this.defaultMute,
    this.onDefaultMuteChanged,
    required this.danmakuEnabled,
    this.onToggleDanmaku,
    this.clearScreen = false,
    this.onToggleClearScreen,
    this.onOpenDanmakuSettings,
    this.rateLabel,
    this.onOpenRate,
    this.qualityLabel,
    this.onOpenQuality,
  });

  final bool fillScreen;
  final ValueChanged<bool>? onFillScreenChanged;
  final bool defaultMute;
  final ValueChanged<bool>? onDefaultMuteChanged;
  final bool danmakuEnabled;
  final VoidCallback? onToggleDanmaku;

  /// 清屏行（官方 `jm3.a`，`oi3/k.java:537-539` 的 `u()`=新面板门）：
  /// 未清屏显示「清屏播放」，清屏态显示「退出清屏」，点击切换并关面板
  /// （`jm3/a.java:76` 的 `p0(!zB0)`）。无回调（不支持清屏/锁定中）不显示。
  final bool clearScreen;
  final VoidCallback? onToggleClearScreen;

  /// 「弹幕设置」入口（官方 `jm3.e`，label `a2v`，在弹幕开关之后）。
  final VoidCallback? onOpenDanmakuSettings;

  /// 倍速/清晰度的**入口行**（行尾是当前档，点击交给宿主开档位弹层）。
  ///
  /// 播放页不放这两行：底栏右下角已经写着当前档，点它直接开档位弹层。
  /// feed 卡片没有那条底栏，长按面板是它唯一的换档入口，所以宿主在这里
  /// 传 label + 回调（[onOpenRate] 非空才出行；清晰度只在多档流在场时传，
  /// 与官方 `oi3/k.P()` 同门）。
  final String? rateLabel;
  final VoidCallback? onOpenRate;
  final String? qualityLabel;
  final VoidCallback? onOpenQuality;

  @override
  State<PlayletMorePanel> createState() => _PlayletMorePanelState();
}

class _PlayletMorePanelState extends State<PlayletMorePanel> {
  late bool _fillScreen;
  late bool _defaultMute;
  late bool _danmakuEnabled;

  @override
  void initState() {
    super.initState();
    _fillScreen = widget.fillScreen;
    _defaultMute = widget.defaultMute;
    _danmakuEnabled = widget.danmakuEnabled;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => ConstrainedBox(
      key: const ValueKey('player-more-panel'),
      constraints: BoxConstraints(maxHeight: constraints.maxHeight * .6),
      child: SafeArea(
        top: false,
        // 底部弹层通栏宽：左边那条竖握时的挖孔不该把整列内容右推。
        left: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              key: const ValueKey('player-more-drag-handle'),
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
            ),
            Flexible(
              child: SingleChildScrollView(
                key: const ValueKey('player-more-scroll'),
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 倍速入口行（官方行序倍速在最前）：只在宿主没有底栏
                    // 当前档可点时出现（feed 长按面板）。
                    if (widget.onOpenRate != null)
                      _actionRow('rate', '倍速', 'rate', () {
                        Navigator.pop(context);
                        widget.onOpenRate!();
                      }, value: widget.rateLabel),
                    // 官方 r() 里清屏行在倍速之后、弹幕之前（jm3.a）。
                    if (widget.onToggleClearScreen != null)
                      _actionRow(
                        'clear',
                        widget.clearScreen ? '退出清屏' : '清屏播放',
                        widget.clearScreen ? 'clear_exit' : 'clear',
                        () {
                          widget.onToggleClearScreen!();
                          Navigator.pop(context);
                        },
                      ),
                    if (widget.onOpenQuality != null)
                      _actionRow('quality', '清晰度', null, () {
                        Navigator.pop(context);
                        widget.onOpenQuality!();
                      }, value: widget.qualityLabel),
                    // V2 的 options 在 actions 上方；保留 o() 中撑满、
                    // 静音、弹幕的相对顺序，省略用户排除及未接入的项目。
                    if (widget.onFillScreenChanged != null)
                      _switchRow('fill', '画面撑满', _fillScreen, () {
                        setState(() => _fillScreen = !_fillScreen);
                        widget.onFillScreenChanged!(_fillScreen);
                      }),
                    if (widget.onDefaultMuteChanged != null)
                      _switchRow('mute', '默认静音', _defaultMute, () {
                        setState(() => _defaultMute = !_defaultMute);
                        widget.onDefaultMuteChanged!(_defaultMute);
                      }),
                    if (widget.onToggleDanmaku != null)
                      _switchRow('danmaku', '弹幕', _danmakuEnabled, () {
                        setState(() => _danmakuEnabled = !_danmakuEnabled);
                        widget.onToggleDanmaku!();
                      }),
                    // 官方 jm3.e：弹幕设置入口只认它自己的门（宿主接得上
                    // 设置面板即可），不跟着弹幕开关回调缺席——与浅色支同门。
                    if (widget.onOpenDanmakuSettings != null)
                      _actionRow(
                        'danmaku_settings',
                        '弹幕设置',
                        'danmaku_settings',
                        widget.onOpenDanmakuSettings!,
                      ),
                    // aae.xml 底部整行「取消」按钮（@string/biu，16sp 居中、
                    // 上下 16dip），点击仅关闭面板。
                    Semantics(
                      key: const ValueKey('player-more-cancel-row'),
                      button: true,
                      child: InkWell(
                        key: const ValueKey('player-more-cancel'),
                        onTap: () => Navigator.pop(context),
                        child: Container(
                          alignment: Alignment.center,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          width: double.infinity,
                          child: const Text('取消', style: _labelStyle),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  /// 官方 jm3.a 行：图标 + 文案（+ 行尾当前值），整行点击，无开关尾件。
  /// [icon] 为空表示该行没有图标（清晰度行官方就是纯文字）。
  Widget _actionRow(
    String id,
    String label,
    String? icon,
    VoidCallback onTap, {
    String? value,
  }) => Semantics(
    key: ValueKey('player-more-$id-row'),
    label: label,
    button: true,
    onTap: onTap,
    excludeSemantics: true,
    child: InkWell(
      onTap: onTap,
      excludeFromSemantics: true,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 52),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 16, 10),
          child: Row(
            children: [
              if (icon != null) ...[_PanelIcon(icon), const SizedBox(width: 6)],
              Expanded(child: Text(label, style: _labelStyle)),
              if (value != null)
                Text(
                  value,
                  key: ValueKey('player-more-$id-value'),
                  style: const TextStyle(
                    fontSize: 14,
                    color: Color(0x99FFFFFF),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _switchRow(String id, String label, bool value, VoidCallback onTap) =>
      Semantics(
        key: ValueKey('player-more-$id-row'),
        label: label,
        toggled: value,
        onTap: onTap,
        excludeSemantics: true,
        child: InkWell(
          onTap: onTap,
          excludeFromSemantics: true,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 52),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 16, 10),
              child: Row(
                children: [
                  _PanelIcon(id),
                  const SizedBox(width: 6),
                  Expanded(child: Text(label, style: _labelStyle)),
                  const SizedBox(width: 12),
                  AnimatedContainer(
                    key: ValueKey('player-more-$id-switch'),
                    duration: const Duration(milliseconds: 300),
                    width: 31,
                    height: 18,
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      color: value
                          ? const Color(0xFFFA6725)
                          : const Color(0x33FFFFFF),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: AnimatedAlign(
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeInOut,
                      alignment: value
                          ? Alignment.centerRight
                          : Alignment.centerLeft,
                      child: const DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                        ),
                        child: SizedBox.square(dimension: 14),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
}

const _labelStyle = TextStyle(fontSize: 14, color: Colors.white);

class _PanelIcon extends StatelessWidget {
  const _PanelIcon(this.name);

  final String name;

  @override
  Widget build(BuildContext context) => Image.asset(
    'assets/images/drama/more_$name.webp',
    width: 24,
    height: 24,
    color: Colors.white,
    excludeFromSemantics: true,
  );
}
