import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../models/media_item.dart';
import 'home_design.dart';

// 档案风格的最小零件：等宽编号、带定位方块的分区标签、一元化的圆角。
//
// 2026-11 首页重做（参照 Wenku8 发现页）：全页只有三档圆角——封面 3、
// 面板 4、按钮胶囊；层级靠细线和等宽编号区分，不再用阴影和彩色角标。

/// 封面圆角。
const double homeCoverRadius = 3;

/// 面板（继续阅读条、空态块）的圆角。
const double homePanelRadius = 4;

/// 网格卡片的字号。卡片和网格行高都从这里取，改一处两边同步。
const double homeCardTitleSize = 14.5;
const double homeCardCodeSize = 9;
const double homeCardMetaSize = 11;

/// 等宽编号的文字样式。中文不走这条样式，只有 ASCII 编号和英文标题用它。
TextStyle homeCodeStyle(HomePalette palette, {Color? color, double size = 9}) =>
    TextStyle(
      fontFamily: 'Home Mono',
      fontFamilyFallback: const [
        'Roboto Mono',
        'Noto Sans Mono',
        'SF Mono',
        'Menlo',
        'Consolas',
        'Courier New',
        'monospace',
      ],
      fontSize: size,
      height: 1.35,
      letterSpacing: 1.05,
      fontWeight: FontWeight.w500,
      color: color ?? palette.muted,
    );

/// 衬线字：书脊与封面兜底图上的竖排书名用它。
///
/// 字体在 `pubspec.yaml` 里声明为 `Home Serif`（思源宋体 SC 子集，GB2312
/// 常用字），粗体走独立的 Bold 字面，不再依赖系统的 "Noto Serif SC" ——
/// Android 的 `serif` 族只注册了拉丁字面，中文会掉回黑体。超出生僻字范围
/// 时由 [homeSerifFallback] 的系统字体兜底。
const List<String> homeSerifFallback = [
  'Noto Serif CJK SC',
  'Noto Serif SC',
  'Source Han Serif SC',
  'Songti SC',
  'SimSun',
  'serif',
];

TextStyle homeSerifStyle({
  required double size,
  required Color color,
  FontWeight weight = FontWeight.w700,
  double height = 1.2,
}) => TextStyle(
  fontFamily: 'Home Serif',
  fontFamilyFallback: homeSerifFallback,
  fontSize: size,
  height: height,
  fontWeight: weight,
  color: color,
);

/// 墨水屏封面的灰度矩阵：按 Rec.709 亮度加权，再按 mockup 的
/// `grayscale(1) contrast(1.15)` 把对比度抬一档（截距 =(1-1.15)×0.5×255）。
///
/// 只给墨水屏用。普通彩色屏仍保留原始封面；墨水屏本来就是灰阶面板，先转灰
/// 能避免系统再做一次不可控的抖动。
const ColorFilter einkCoverFilter = ColorFilter.matrix(<double>[
  0.24449, 0.82248, 0.08303, 0, -19.125, //
  0.24449, 0.82248, 0.08303, 0, -19.125, //
  0.24449, 0.82248, 0.08303, 0, -19.125, //
  0, 0, 0, 1, 0, //
]);

/// 一行等宽编号（`SHIJINPU / STORY ARCHIVE`、`NO.001`、`NOV-12048`）。
class HomeCode extends StatelessWidget {
  const HomeCode(this.text, {super.key, this.size = 9, this.color, this.align});

  final String text;
  final double size;
  final Color? color;
  final TextAlign? align;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: align,
      style: homeCodeStyle(palette, size: size, color: color),
    );
  }
}

/// 分区标签：等宽编号 → 一条细线 → 一个 4dp 定位方块，下一行是标题。
///
/// 编号是真实顺序（01 排行榜、02 为你推荐），不是装饰序号。
class HomeSectionLabel extends StatelessWidget {
  const HomeSectionLabel({
    super.key,
    required this.code,
    required this.title,
    this.action,
    this.gutter = 16,
  });

  final String code;
  final String title;
  final Widget? action;
  final double gutter;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(gutter, 16, gutter, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              HomeCode(code),
              const SizedBox(width: 10),
              Expanded(child: Container(height: 1, color: palette.line)),
              const SizedBox(width: 8),
              Container(width: 4, height: 4, color: palette.mark),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 18,
                    height: 1.25,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.4,
                    color: palette.ink,
                  ),
                ),
              ),
              if (action != null) ...[const SizedBox(width: 12), action!],
            ],
          ),
        ],
      ),
    );
  }
}

/// 「完整榜单」这类次级动作：等宽编号的字重，加一个箭头。
class HomeSectionAction extends StatelessWidget {
  const HomeSectionAction({
    super.key,
    required this.label,
    required this.onTap,
  });

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return HomePressable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(homePanelRadius),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(fontSize: 12, height: 1.2, color: palette.muted),
            ),
            const SizedBox(width: 2),
            Icon(LucideIcons.chevron_right, size: 13, color: palette.muted),
          ],
        ),
      ),
    );
  }
}

/// 一本书的档案编号：媒介前缀 + id 的后五位（`NOV-12048`）。
///
/// 编号只是「同一本书始终得到同一串字」的稳定标识，不承担排序语义。
String homeFileCode(MediaItem item) {
  final prefix = switch (item.kind) {
    'video' => 'VID',
    'manju' => 'MNJ',
    'manga' => 'MNG',
    'audio' => 'AUD',
    _ => 'NOV',
  };
  final digits = item.id.replaceAll(RegExp(r'[^0-9]'), '');
  final tail = digits.length >= 5
      ? digits.substring(digits.length - 5)
      : digits.padLeft(5, '0');
  return '$prefix-$tail';
}
