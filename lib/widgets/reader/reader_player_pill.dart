import 'package:flutter/material.dart';

import '../../pages/audio_page.dart' show AudioPlaybackScope;
import '../../services/listening_session.dart';

/// 官方 `ReaderPlayerButton`（布局 `ajo.xml` 的 `TextView j53`）。
///
/// 阅读页底部居中的那枚胶囊：正在朗读时显示「暂停播放」+ 暂停图标，暂停时
/// 显示「继续播放」+ 播放三角，点一下切换。官方取值（截图实测 + XML）：
///
/// * 高 32dp，14sp，单行；
/// * 左内边距 18dp、右 20dp，图标 14dp，图标与文字间距 4dp；
/// * 底色 `#7E6F52`、文字与图标 `#FEF1E0`（浅色主题下取样）；
/// * 水平居中，距屏幕底部约 34dp（压在本章进度行上方）。
class ReaderPlayerPill extends StatelessWidget {
  const ReaderPlayerPill({
    super.key,
    required this.playing,
    required this.onTap,
    this.compact = false,
  });

  final bool playing;
  final VoidCallback onTap;

  /// 官方 `ButtonType.indicator`：只有图标、没有文字。
  ///
  /// 触发条件是「正在播放 **且** 朗读高亮在屏幕内」（`audiosync/a.a()`
  /// 的三条判据）；暂停或高亮滚出屏幕时回到完整胶囊。
  final bool compact;

  static const double height = 32;
  static const Color _background = Color(0xFF7E6F52);
  static const Color _foreground = Color(0xFFFEF1E0);

  @override
  Widget build(BuildContext context) {
    return Material(
      color: _background,
      borderRadius: BorderRadius.circular(height / 2),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: const ValueKey('reader_player_pill'),
        onTap: onTap,
        child: SizedBox(
          height: height,
          width: compact ? height : null,
          child: Padding(
            padding: compact
                ? EdgeInsets.zero
                : const EdgeInsets.only(left: 18, right: 20),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  playing ? Icons.pause : Icons.play_arrow,
                  size: 14,
                  color: _foreground,
                ),
                if (!compact) ...[
                  const SizedBox(width: 4),
                  Text(
                    playing ? '暂停播放' : '继续播放',
                    key: const ValueKey('reader_player_pill_label'),
                    maxLines: 1,
                    style: const TextStyle(
                      color: _foreground,
                      fontSize: 14,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 阅读页里的胶囊覆盖层：自己判断该不该出现、自己处理点击。
///
/// 抽成组件是为了让 [ReaderPage] 只多一行 —— 那个文件本来就在行数预算上限。
class ReaderPlayerPillOverlay extends StatelessWidget {
  const ReaderPlayerPillOverlay({
    super.key,
    required this.bookId,
    this.highlightOnScreen = false,
  });

  final String bookId;

  /// 朗读高亮是否落在当前屏内；官方据此把按钮缩成图标态。
  final bool highlightOnScreen;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 34),
          child: Center(
            child: ListenableBuilder(
              listenable: ListeningSession.instance,
              builder: (context, _) {
                final session = ListeningSession.instance;
                // 没在听这本书（或根本没起播）就不占位。
                if (session.bookId != bookId) return const SizedBox.shrink();
                return ReaderPlayerPill(
                  playing: session.playing,
                  // 官方：播放中且高亮在屏内 → 缩成图标，别挡正文。
                  compact: session.playing && highlightOnScreen,
                  onTap: () =>
                      AudioPlaybackScope.togglePlayback(context, bookId),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
