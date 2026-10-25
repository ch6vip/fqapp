import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 播放页的轻量提示，替代底部通栏 [SnackBar]。
///
/// SnackBar 在播放页有两个问题：横屏下会铺满整条屏幕宽度，且带一层
/// 抬升式背景；横屏播放器的提示应当是画面底部一条居中的圆角胶囊
/// （与官方 Toast 同观感）。这里用 Overlay 自管一条，全局只保留最新
/// 的那条：新的直接顶掉旧的，淡入 → 停留 → 淡出共 2 秒后自摘。
///
/// 停留段用 [Timer] 而不是让动画控制器一直跑：控制器跑着会每帧都要新的
/// frame，`pumpAndSettle` 会一路推进到提示消失，测试里就查不到文案了
/// （SnackBar 同理，靠 Timer 停在屏幕上）。Timer 在 dispose 里取消，
/// 不会给测试留下待触发的定时器。
class PlayerToast {
  PlayerToast._();

  /// 淡入 150ms + 停留 1.7s + 淡出 150ms。
  static const Duration total = Duration(milliseconds: 2000);
  static const Duration fade = Duration(milliseconds: 150);

  static OverlayEntry? _entry;

  /// 在 [context] 所在的根 Overlay 弹一条提示。
  ///
  /// [bottom] 为空时自己算：竖屏压在底栏之上（安全区 + 96dp），横屏要
  /// 让开 132dp 的底条（时间行 / 进度条 / 控制行）。
  static void show(BuildContext context, String message, {double? bottom}) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null || message.isEmpty) return;
    hide();
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _PlayerToastView(
        message: message,
        bottom: bottom,
        onFinished: () {
          if (_entry != entry) return;
          _entry = null;
          if (entry.mounted) entry.remove();
        },
      ),
    );
    _entry = entry;
    overlay.insert(entry);
  }

  /// 立即摘掉当前提示（页面退出时调用，避免残留到别的页面上）。
  static void hide() {
    final entry = _entry;
    _entry = null;
    if (entry != null && entry.mounted) entry.remove();
  }
}

class _PlayerToastView extends StatefulWidget {
  const _PlayerToastView({
    required this.message,
    required this.bottom,
    required this.onFinished,
  });

  final String message;
  final double? bottom;
  final VoidCallback onFinished;

  @override
  State<_PlayerToastView> createState() => _PlayerToastViewState();
}

class _PlayerToastViewState extends State<_PlayerToastView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: PlayerToast.fade,
  );

  late final Animation<double> _fade = Tween(
    begin: 0.0,
    end: 1.0,
  ).chain(CurveTween(curve: Curves.easeOut)).animate(_controller);

  /// 淡入时轻微上浮（8dp），比纯淡入更有「弹出」感。
  late final Animation<double> _rise = Tween(
    begin: 8.0,
    end: 0.0,
  ).chain(CurveTween(curve: Curves.easeOutCubic)).animate(_controller);

  Timer? _holdTimer;

  @override
  void initState() {
    super.initState();
    _controller.forward();
    _holdTimer = Timer(PlayerToast.total - PlayerToast.fade, _dismiss);
  }

  Future<void> _dismiss() async {
    if (!mounted) return;
    await _controller.reverse();
    if (mounted) widget.onFinished();
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final insets = MediaQuery.paddingOf(context);
    final size = MediaQuery.sizeOf(context);
    // 横屏的底条高 132dp，竖屏底栏约 96dp：横屏提示再抬高一点，短窗口下
    // 也不能顶到画面上半区（所以夹一个 45% 高的上限）。
    final landscape = size.width > size.height;
    final fallback = landscape
        ? math.min(math.max(insets.bottom + 96, 150.0), size.height * .45)
        : insets.bottom + 96;
    final bottom = widget.bottom ?? fallback;
    return Positioned.fill(
      child: IgnorePointer(
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: EdgeInsets.fromLTRB(24, 0, 24, bottom),
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, child) => Opacity(
                opacity: _fade.value,
                child: Transform.translate(
                  offset: Offset(0, _rise.value),
                  child: child,
                ),
              ),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.sizeOf(context).width * .82,
                ),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: const Color(0xE6161616),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 9,
                    ),
                    child: Text(
                      widget.message,
                      key: const ValueKey('player-toast'),
                      maxLines: 2,
                      textAlign: TextAlign.center,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        height: 1.3,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
