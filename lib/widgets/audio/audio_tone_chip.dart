import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../models/audio_extra.dart';
import '../../services/audio_page_theme.dart';
import '../home/home_design.dart';

/// 官方音色片（`bj1.xml` 里 `x6` 那个横向 RecyclerView 的 item）。
///
/// 截图量到的规格：选中片是接近白的底且**没有描边**，未选片比画布再暗一档；
/// 片内是 15sp 粗标题 + 12.5sp 副标题；多角色音色在右上角挂一片「多角色」
/// 丝带（底色 `#F0E7E8`、字色 `#5B2D2D`、左下大圆角、右上贴合卡片圆角）。
class AudioToneChip extends StatelessWidget {
  /// 官方圆角，约 12dp。
  static const double radius = 12;

  /// 官方片宽，约 132dp。
  static const double width = 132;

  final AudioTone tone;
  final double height;
  final bool selected;
  final VoidCallback onTap;

  const AudioToneChip({
    super.key,
    required this.tone,
    required this.height,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = AudioPageThemeScope.of(context);
    return HomePressable(
      key: ValueKey('audio_tone_${tone.id}'),
      semanticLabel: '选择音色 ${tone.title}',
      onTap: onTap,
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: width,
        height: height,
        child: ClipRRect(
          // 丝带的右上角要靠这层裁出卡片的圆角，所以 Stack 必须在 ClipRRect 内。
          borderRadius: BorderRadius.circular(radius),
          child: Stack(
            children: [
              Positioned.fill(child: _label(theme)),
              if (tone.isMultiTone)
                Positioned(
                  top: 0,
                  right: 0,
                  child: AudioMultiRoleRibbon(toneId: tone.id),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _label(AudioPageTheme theme) {
    // 选中：向白抬 45%；未选：向墨色压 14%。两档都以画布为基准，
    // 换一本书（换一套取色）时仍保持同样的层次关系。
    final fill = selected
        ? Color.lerp(theme.canvas, Colors.white, 0.45)!
        : Color.lerp(theme.canvas, theme.ink, 0.14)!;
    return ColoredBox(
      color: fill,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    tone.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: theme.ink,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (tone.isMultiTone) ...[
                  const SizedBox(width: 4),
                  Icon(LucideIcons.audio_lines, size: 15, color: theme.ink),
                ],
              ],
            ),
            if (tone.description.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                tone.description,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: theme.muted, fontSize: 12.5),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 音色片右上角的「多角色」丝带。
class AudioMultiRoleRibbon extends StatelessWidget {
  final String toneId;

  const AudioMultiRoleRibbon({super.key, required this.toneId});

  @override
  Widget build(BuildContext context) {
    final theme = AudioPageThemeScope.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 3, 9, 3),
      decoration: BoxDecoration(
        // 比画布略压一点，正好落在选中片与卡片之间的一档。
        color: Color.lerp(theme.canvas, theme.ink, 0.06),
        borderRadius: const BorderRadius.only(
          bottomLeft: Radius.circular(10),
        ),
      ),
      child: Text(
        '多角色',
        key: ValueKey('audio_tone_multi_$toneId'),
        style: TextStyle(
          color: theme.ink,
          fontSize: 11,
          height: 1.2,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
