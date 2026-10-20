import 'dart:typed_data';

import '../../services/reader_preferences.dart';

/// 墨水屏阅读的纯逻辑决策，抽出来是为了可单测；接线只在 reader_page 里。
///
/// 背景：墨水屏上任何动画帧都会留残影，所以墨水屏模式必须：
/// - 翻页零动画（翻页方式强制“无”+ 滑动直翻，章节边界动画也随之跳过，
///   因为 ReaderPagedView 在 turnStyle == none 时不播章节转场）；
/// - 正文最低 500 字重（Flutter 没有开关亚像素抗锯齿的 API，加粗是唯一
///   能用的笔画加深手段；用户自选更高字重时保留）。
ReaderPageTurnStyle einkEffectiveTurnStyle({
  required bool eink,
  required bool instantSwipeTurn,
  required ReaderPageTurnStyle pageTurnStyle,
}) {
  if (eink || instantSwipeTurn) return ReaderPageTurnStyle.none;
  return pageTurnStyle;
}

bool einkEffectiveInstantSwipe({
  required bool eink,
  required bool instantSwipeTurn,
}) => eink || instantSwipeTurn;

int einkEffectiveFontWeight({required bool eink, required int fontWeight}) {
  if (!eink) return fontWeight;
  return fontWeight < 500 ? 500 : fontWeight;
}

/// 把 RGBA 字节就地转成墨水屏友好的灰度抖动图。
///
/// 先按亮度转灰度，再用 Floyd–Steinberg 误差扩散量化到 16 档灰阶
/// （4-bit，KOReader 等墨水屏阅读器的常用做法）：纯灰度去掉彩色量化噪点，
/// 抖动保留照片/插图的渐变层次，比面板自己量化更干净。
/// 只动 RGB 三通道，Alpha 原样保留；输入长度必须是 width * height * 4。
Uint8List einkDitherPixels(Uint8List rgba, int width, int height) {
  final out = Uint8List.fromList(rgba);
  const levels = 16;
  const step = 255.0 / (levels - 1);
  // 误差扩散按行处理：把当前像素量化后，把误差按 7/16、3/16、5/16、1/16
  // 分给右、左下、下、右下四个邻居。只保留当前行与下一行的误差（两行缓冲），
  // 不存整图误差表，避免大图多占几十 MB。
  var currentRow = Float64List(width);
  var nextRow = Float64List(width);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final i = (y * width + x) * 4;
      final r = out[i].toDouble();
      final g = out[i + 1].toDouble();
      final b = out[i + 2].toDouble();
      var gray = 0.299 * r + 0.587 * g + 0.114 * b;
      gray += currentRow[x];
      final quantized = (gray / step).round().clamp(0, levels - 1) * step;
      final err = gray - quantized;
      out[i] = quantized.round();
      out[i + 1] = quantized.round();
      out[i + 2] = quantized.round();
      if (x + 1 < width) currentRow[x + 1] += err * 7 / 16;
      if (y + 1 < height) {
        if (x > 0) nextRow[x - 1] += err * 3 / 16;
        nextRow[x] += err * 5 / 16;
        if (x + 1 < width) nextRow[x + 1] += err * 1 / 16;
      }
    }
    final tmp = currentRow;
    currentRow = nextRow;
    nextRow = tmp;
    nextRow.fillRange(0, width, 0);
  }
  return out;
}
