import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../services/audio_page_theme.dart';
import '../home/home_design.dart';

/// 章末连播倒计时条。
///
/// 官方是 `te`「%s后播放下一集」：章节播完不立刻跳，给一段可取消的窗口。
/// 归零后由控制器打开下一章，这一条只负责显示与取消。
class AudioAdvanceBanner extends StatelessWidget {
  /// 剩余秒数。
  final int seconds;
  final VoidCallback onCancel;

  const AudioAdvanceBanner({
    super.key,
    required this.seconds,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final theme = AudioPageThemeScope.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 2),
      child: Container(
        key: const Key('audio_advance_banner'),
        padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
        decoration: BoxDecoration(
          color: theme.card,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Icon(LucideIcons.skip_forward, size: 16, color: theme.muted),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '$seconds 秒后播放下一集',
                key: const Key('audio_advance_countdown'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: theme.ink, fontSize: 13),
              ),
            ),
            HomePressable(
              key: const Key('audio_advance_cancel'),
              semanticLabel: '取消自动播放下一集',
              onTap: onCancel,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                child: Text(
                  '取消',
                  style: TextStyle(
                    color: theme.accent,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
