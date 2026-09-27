import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../services/player_preferences.dart';

// Note: 官方分支、档位动画和关闭边界见
// .agents/notes/implemented/feature/2026-09-26-playlet-more-panel.md
class PlayletMorePanel extends StatefulWidget {
  const PlayletMorePanel({
    super.key,
    required this.rate,
    required this.fillScreen,
    this.onFillScreenChanged,
    required this.defaultMute,
    this.onDefaultMuteChanged,
    required this.danmakuEnabled,
    this.onToggleDanmaku,
    this.clearScreen = false,
    this.onToggleClearScreen,
    this.onOpenDanmakuSettings,
  });

  final double rate;
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

  @override
  State<PlayletMorePanel> createState() => _PlayletMorePanelState();
}

class _PlayletMorePanelState extends State<PlayletMorePanel> {
  final _rates = ScrollController();
  late double _rate;
  late bool _fillScreen;
  late bool _defaultMute;
  late bool _danmakuEnabled;
  bool _ratePending = false;
  double _optionWidth = 48;
  double? _dragPosition;

  @override
  void initState() {
    super.initState();
    _rate = widget.rate;
    _fillScreen = widget.fillScreen;
    _defaultMute = widget.defaultMute;
    _danmakuEnabled = widget.danmakuEnabled;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_dragPosition != null) {
      _dragPosition = null;
      _rate = widget.rate;
      _ratePending = false;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_rates.hasClients) return;
      final start =
          PlayerPreferences.playbackRates.indexOf(_rate) * _optionWidth;
      final end = start + _optionWidth;
      final offset = _rates.offset;
      final visibleEnd = offset + _rates.position.viewportDimension;
      if (start < offset || end > visibleEnd) {
        _rates.jumpTo(
          (start < offset ? start : end - _rates.position.viewportDimension)
              .clamp(0.0, _rates.position.maxScrollExtent),
        );
      }
    });
  }

  @override
  void dispose() {
    _rates.dispose();
    super.dispose();
  }

  void _selectRate(double rate) {
    if (rate == _rate || _dragPosition != null) return;
    setState(() {
      _rate = rate;
      _ratePending = true;
    });
  }

  void _startRateDrag(DragStartDetails details) {
    setState(() {
      _ratePending = false;
      _dragPosition =
          PlayerPreferences.playbackRates.indexOf(_rate) * _optionWidth;
    });
  }

  void _updateRateDrag(DragUpdateDetails details) {
    if (_dragPosition == null) return;
    setState(() {
      _dragPosition = (_dragPosition! + details.delta.dx).clamp(
        0.0,
        (PlayerPreferences.playbackRates.length - 1) * _optionWidth,
      );
    });
  }

  void _endRateDrag(DragEndDetails details) {
    if (_dragPosition == null) return;
    final position = _dragPosition!;
    final index = (position / _optionWidth).round();
    setState(() {
      _dragPosition = null;
      _rate = PlayerPreferences.playbackRates[index];
      _ratePending = _rate != widget.rate;
    });
    // 恰好停在档位上时不会触发隐式动画的 onEnd。
    if ((position - index * _optionWidth).abs() < .01) {
      _finishRateSelection();
    }
  }

  void _cancelRateDrag() {
    if (_dragPosition == null) return;
    setState(() {
      _dragPosition = null;
      _rate = widget.rate;
      _ratePending = false;
    });
  }

  void _finishRateSelection() {
    if (!_ratePending) return;
    _ratePending = false;
    // 点外部/返回可能先关闭 route；退场期间的动画不能再弹出播放页。
    if (ModalRoute.of(context)?.isCurrent != true) return;
    Navigator.of(context).pop(_rate);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => ConstrainedBox(
      key: const ValueKey('player-more-panel'),
      constraints: BoxConstraints(maxHeight: constraints.maxHeight * .6),
      child: SafeArea(
        top: false,
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
                    _rateRow(context),
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
                    if (widget.onToggleDanmaku != null) ...[
                      _switchRow('danmaku', '弹幕', _danmakuEnabled, () {
                        setState(() => _danmakuEnabled = !_danmakuEnabled);
                        widget.onToggleDanmaku!();
                      }),
                      if (widget.onOpenDanmakuSettings != null)
                        _actionRow(
                          'danmaku_settings',
                          '弹幕设置',
                          'danmaku_settings',
                          widget.onOpenDanmakuSettings!,
                        ),
                    ],
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

  Widget _rateRow(BuildContext context) {
    final fontSize = MediaQuery.textScalerOf(context).scale(14);
    _optionWidth = 48 * math.max(1, fontSize / 14);
    final rowHeight = math.max(54.0, fontSize * 1.4 + 20);
    final highlightedRate = _dragPosition == null
        ? _rate
        : PlayerPreferences.playbackRates[(_dragPosition! / _optionWidth)
              .round()];
    return Padding(
      key: const ValueKey('player-more-rate-row'),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          const _PanelIcon('rate'),
          const SizedBox(width: 6),
          const Text('倍速', style: _labelStyle),
          const SizedBox(width: 28),
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: SingleChildScrollView(
                key: const ValueKey('player-more-rate-scroll'),
                controller: _rates,
                scrollDirection: Axis.horizontal,
                physics: const ClampingScrollPhysics(),
                child: SizedBox(
                  width: _optionWidth * PlayerPreferences.playbackRates.length,
                  height: rowHeight,
                  child: Stack(
                    children: [
                      AnimatedPositioned(
                        duration: _dragPosition == null
                            ? const Duration(milliseconds: 300)
                            : Duration.zero,
                        curve: Curves.decelerate,
                        onEnd: _finishRateSelection,
                        left:
                            _dragPosition ??
                            PlayerPreferences.playbackRates.indexOf(_rate) *
                                _optionWidth,
                        width: _optionWidth,
                        top: 11,
                        bottom: 11,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: const Color(0x33FFFFFF),
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                      ),
                      Row(
                        children: [
                          for (final rate in PlayerPreferences.playbackRates)
                            _rateOption(rate, rowHeight, highlightedRate),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _rateOption(
    double rate,
    double height,
    double highlightedRate,
  ) => Semantics(
    key: ValueKey('player-more-rate-$rate'),
    label: '$rate 倍速',
    button: true,
    selected: rate == _rate,
    onTap: () => _selectRate(rate),
    excludeSemantics: true,
    child: InkWell(
      onTap: () => _selectRate(rate),
      excludeFromSemantics: true,
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: _optionWidth,
        height: height,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 11),
          // 官方从选中滑块起拖时选档，其余区域横滑浏览档位。
          child: Listener(
            // 已接受的拖动收到 PointerCancel 时也可能走 onEnd。
            onPointerCancel: (_) => _cancelRateDrag(),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragStart: rate == _rate ? _startRateDrag : null,
              onHorizontalDragUpdate: rate == _rate ? _updateRateDrag : null,
              onHorizontalDragEnd: rate == _rate ? _endRateDrag : null,
              onHorizontalDragCancel: rate == _rate ? _cancelRateDrag : null,
              child: Center(
                child: Text(
                  '${rate == rate.roundToDouble() ? rate.toInt() : rate}x',
                  style: _labelStyle.copyWith(
                    color: rate == highlightedRate
                        ? Colors.white
                        : const Color(0x80FFFFFF),
                    fontWeight: rate == highlightedRate
                        ? FontWeight.bold
                        : FontWeight.normal,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  /// 官方 jm3.a 行：图标 + 文案，整行点击，无开关尾件。
  Widget _actionRow(String id, String label, String icon, VoidCallback onTap) =>
      Semantics(
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
                  _PanelIcon(icon),
                  const SizedBox(width: 6),
                  Expanded(child: Text(label, style: _labelStyle)),
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
