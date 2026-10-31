import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 听书页的进度区：时间文案 + 进度条。
///
/// 原生位置流约 5Hz。位置从 [position] 这个 notifier 推进来，只有本部件跟着
/// 重建；封面、集名、播放按钮与倍速药丸都不参与。拖动期间只做本地预览，
/// [onSeek] 只在松手时提交一次——逐帧 seek 会把原生 seek 打爆。
class ListenProgressBar extends StatefulWidget {
  const ListenProgressBar({
    super.key,
    required this.position,
    required this.duration,
    required this.onSeek,
  });

  final ValueListenable<Duration> position;

  /// 总时长单独走 notifier：原生在 `created` 之后才发 `duration`，
  /// build 时的快照可能还是 0，不能拖到下一次整页重建才更新。
  final ValueListenable<Duration> duration;

  /// 松手时把目标比例（0–1）交给宿主 seek。
  final ValueChanged<double> onSeek;

  @override
  State<ListenProgressBar> createState() => _ListenProgressBarState();
}

class _ListenProgressBarState extends State<ListenProgressBar> {
  /// 拖动中的本地预览比例；null 表示跟随播放位置。
  double? _dragFraction;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Duration>(
      valueListenable: widget.position,
      builder: (context, position, _) => ValueListenableBuilder<Duration>(
        valueListenable: widget.duration,
        builder: (context, duration, _) {
          final seekable = duration.inMilliseconds > 0;
          final fraction = seekable
              ? (position.inMilliseconds / duration.inMilliseconds).clamp(
                  0.0,
                  1.0,
                )
              : 0.0;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '${_fmt(position)} / ${_fmt(duration)}',
                key: const ValueKey('listen-time'),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12, color: Color(0x99FFFFFF)),
              ),
              Slider(
                key: const ValueKey('listen-seek'),
                value: seekable ? _dragFraction ?? fraction : 0,
                onChanged: seekable
                    ? (value) => setState(() => _dragFraction = value)
                    : null,
                onChangeEnd: seekable
                    ? (value) {
                        setState(() => _dragFraction = null);
                        widget.onSeek(value);
                      }
                    : null,
                activeColor: const Color(0xFFFA6725),
              ),
            ],
          );
        },
      ),
    );
  }

  static String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}
