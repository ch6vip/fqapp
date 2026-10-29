import 'package:flutter/material.dart';

/// 播放页那颗「全屏观看 / 退出全屏」胶囊。
///
/// 三个形态共用同一个组件，避免文案与内边距各写一份：竖屏目录态的
/// `_portraitControls`、通用播放器的信息区，以及竖屏全屏那条贴底窄带
/// （竖屏全屏没有横屏底条，顶栏返回又会随控件收起，只能在这里留出口）。
///
/// 胶囊自带 `player-fullscreen-pill` key：调用方一次只会渲染一处。
class PlayletFullscreenPill extends StatelessWidget {
  const PlayletFullscreenPill({
    super.key,
    required this.fullScreen,
    required this.shortSeries,
    this.onTap,
  });

  /// 当前是否已全屏，决定文案是「退出全屏」还是「全屏观看」。
  final bool fullScreen;

  /// 短剧按 `aqh.xml` 的 5dp 纵向内边距，通用播放器保留 `aqi.xml` 的 8dp。
  /// 官方存在配置分支，不能把其中一套当作唯一规格。
  final bool shortSeries;

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    child: GestureDetector(
      key: const ValueKey('player-fullscreen-pill'),
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: 16,
          vertical: shortSeries ? 5 : 8,
        ),
        decoration: BoxDecoration(
          color: const Color(0xB3262626),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset(
              'assets/images/drama/fullscreen.webp',
              width: 20,
              height: 20,
              fit: BoxFit.contain,
            ),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                fullScreen ? '退出全屏' : '全屏观看',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
