import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

/// Cover hue for the official audio capsule, the colour
/// `PaletteUtils.getColorHByPalette` picks (`com/dragon/read/base/ui/util`).
///
/// Builds AndroidX Palette's default swatches, then takes the first hue in
/// the official priority: muted, lightMuted, darkMuted, vibrant,
/// darkVibrant, dominant. Returns null when the cover has no usable colour.
double? coverPaletteHueFromRgba(Uint8List rgba, {int stride = 1}) {
  final swatches = _paletteSwatches(rgba, stride: stride);
  if (swatches.isEmpty) return null;
  var dominant = swatches.first;
  for (final swatch in swatches) {
    if (swatch.population > dominant.population) dominant = swatch;
  }
  // Palette.generate() 按固定顺序逐个目标取 swatch，且 swatch 互斥：
  // 先被 vibrant 系列挑走的颜色不会再参与 muted 的评选，与官方一致。
  final used = <int>{};
  final selected = <_PaletteTarget, _PaletteSwatch>{};
  for (final target in _PaletteTarget.generationOrder) {
    _PaletteSwatch? best;
    var bestScore = 0.0;
    for (final swatch in swatches) {
      if (used.contains(swatch.argb) || !target.accepts(swatch)) continue;
      final score = target.score(swatch, dominant.population);
      if (best == null || score > bestScore) {
        best = swatch;
        bestScore = score;
      }
    }
    if (best != null) {
      selected[target] = best;
      used.add(best.argb);
    }
  }
  return (selected[_PaletteTarget.muted] ??
          selected[_PaletteTarget.lightMuted] ??
          selected[_PaletteTarget.darkMuted] ??
          selected[_PaletteTarget.vibrant] ??
          selected[_PaletteTarget.darkVibrant] ??
          dominant)
      .hue;
}

/// AndroidX Palette（`androidx.palette.graphics`）默认目标的精简复刻。
///
/// 每个目标给出饱和度/明度的可接受区间与评分中心；权重来自
/// `Palette.Target` 的默认值（0.24 / 0.52 / 0.24），三者和为 1。
@immutable
class _PaletteTarget {
  const _PaletteTarget({
    required this.minSaturation,
    required this.maxSaturation,
    required this.saturationTarget,
    required this.minLightness,
    required this.maxLightness,
    required this.lightnessTarget,
  });

  final double minSaturation;
  final double maxSaturation;
  final double saturationTarget;
  final double minLightness;
  final double maxLightness;
  final double lightnessTarget;

  /// `Palette.Builder` 的默认目标生成顺序：先到先得。
  static const generationOrder = <_PaletteTarget>[
    lightVibrant,
    vibrant,
    darkVibrant,
    lightMuted,
    muted,
    darkMuted,
  ];

  static const lightVibrant = _PaletteTarget(
    minSaturation: 0.35,
    maxSaturation: 1,
    saturationTarget: 1,
    minLightness: 0.55,
    maxLightness: 1,
    lightnessTarget: 0.74,
  );
  static const vibrant = _PaletteTarget(
    minSaturation: 0.35,
    maxSaturation: 1,
    saturationTarget: 1,
    minLightness: 0.3,
    maxLightness: 0.7,
    lightnessTarget: 0.5,
  );
  static const darkVibrant = _PaletteTarget(
    minSaturation: 0.35,
    maxSaturation: 1,
    saturationTarget: 1,
    minLightness: 0,
    maxLightness: 0.45,
    lightnessTarget: 0.26,
  );
  static const lightMuted = _PaletteTarget(
    minSaturation: 0,
    maxSaturation: 0.4,
    saturationTarget: 0.3,
    minLightness: 0.55,
    maxLightness: 1,
    lightnessTarget: 0.74,
  );
  static const muted = _PaletteTarget(
    minSaturation: 0,
    maxSaturation: 0.4,
    saturationTarget: 0.3,
    minLightness: 0.3,
    maxLightness: 0.7,
    lightnessTarget: 0.5,
  );
  static const darkMuted = _PaletteTarget(
    minSaturation: 0,
    maxSaturation: 0.4,
    saturationTarget: 0.3,
    minLightness: 0,
    maxLightness: 0.45,
    lightnessTarget: 0.26,
  );

  bool accepts(_PaletteSwatch swatch) =>
      swatch.saturation >= minSaturation &&
      swatch.saturation <= maxSaturation &&
      swatch.lightness >= minLightness &&
      swatch.lightness <= maxLightness;

  /// 与 `Palette.generateScore` 相同：饱和度/明度越接近目标分越高，
  /// 再加上 swatch 相对主色的占比。
  double score(_PaletteSwatch swatch, int dominantPopulation) =>
      0.24 * (1 - (swatch.saturation - saturationTarget).abs()) +
      0.52 * (1 - (swatch.lightness - lightnessTarget).abs()) +
      (dominantPopulation <= 0
          ? 0
          : 0.24 * swatch.population / dominantPopulation);
}

/// Palette 的一个色块：Palette 内部是 quantize 后的平均值加人数。
class _PaletteSwatch {
  _PaletteSwatch.fromArgb(this.argb, this.population)
    : _hsl = HSLColor.fromColor(Color(argb));

  final int argb;
  final int population;
  final HSLColor _hsl;

  double get hue => _hsl.hue;
  double get saturation => _hsl.saturation;
  double get lightness => _hsl.lightness;
}

/// Palette 默认最多保留的色块数（`Builder.mMaxColors`）。
const _maxPaletteSwatches = 16;

/// 复刻 `ColorCutQuantizer`：5 bit/通道量化 + 默认过滤器 + 中位切分。
List<_PaletteSwatch> _paletteSwatches(Uint8List rgba, {int stride = 1}) {
  final counts = <int, int>{};
  final step = stride < 1 ? 1 : stride;
  final pixels = rgba.length ~/ 4;
  for (var i = 0; i < pixels; i += step) {
    final o = i * 4;
    // 透明像素（PNG 封面常见）不参与投票，与 dominantFromRgba 一致。
    if (rgba[o + 3] < 128) continue;
    final key =
        (((rgba[o] >> 3) << 10) |
        ((rgba[o + 1] >> 3) << 5) |
        (rgba[o + 2] >> 3));
    // Palette 在量化阶段就丢掉近黑/近白/红橙色带，且过滤的是反量化后的颜色。
    if (!_paletteAllows(_dequantize(key))) continue;
    counts[key] = (counts[key] ?? 0) + 1;
  }
  final keys = counts.keys.toList();
  if (keys.length <= _maxPaletteSwatches) {
    return [
      for (final key in keys)
        _PaletteSwatch.fromArgb(_dequantize(key), counts[key]!),
    ].where((swatch) => _paletteAllows(swatch.argb)).toList();
  }
  return [
    for (final box in _medianCut(keys, counts)) _averageSwatch(box, counts),
  ].where((swatch) => _paletteAllows(swatch.argb)).toList();
}

/// AndroidX Palette 默认过滤器：去掉 lightness ≤ 0.05、≥ 0.95 以及
/// 「色相 10°–37° 且饱和度 ≤ 0.82」的红橙色带。
bool _paletteAllows(int argb) {
  final hsl = HSLColor.fromColor(Color(argb));
  if (hsl.lightness <= 0.05 || hsl.lightness >= 0.95) return false;
  return !(hsl.hue >= 10 && hsl.hue <= 37 && hsl.saturation <= 0.82);
}

/// 5 bit 量化键反量化回 8 bit：与 Palette 一样直接把低位补零。
int _dequantize(int key) =>
    0xFF000000 |
    (((key >> 10) & 31) << 19) |
    (((key >> 5) & 31) << 11) |
    ((key & 31) << 3);

int _channel(int key, int shift) => (key >> shift) & 31;

/// 按 Palette 的 VBox 规则做中位切分，直到得到 [_maxPaletteSwatches] 个盒子。
List<List<int>> _medianCut(List<int> keys, Map<int, int> counts) {
  final boxes = <List<int>>[keys];
  while (boxes.length < _maxPaletteSwatches) {
    var pick = -1;
    var largest = -1;
    for (var i = 0; i < boxes.length; i++) {
      if (boxes[i].length < 2) continue;
      final volume = _boxVolume(boxes[i]);
      if (volume > largest) {
        largest = volume;
        pick = i;
      }
    }
    if (pick < 0) break;
    final box = boxes[pick];
    final shift = _widestChannel(box);
    box.sort((a, b) => _channel(a, shift).compareTo(_channel(b, shift)));
    var total = 0;
    for (final key in box) {
      total += counts[key]!;
    }
    var running = 0;
    var cut = box.length - 2;
    for (var i = 0; i < box.length; i++) {
      running += counts[box[i]]!;
      if (running >= total ~/ 2) {
        cut = math.min(i, box.length - 2);
        break;
      }
    }
    boxes[pick] = box.sublist(0, cut + 1);
    boxes.add(box.sublist(cut + 1));
  }
  return boxes;
}

int _boxVolume(List<int> box) {
  var minR = 31, maxR = 0, minG = 31, maxG = 0, minB = 31, maxB = 0;
  for (final key in box) {
    final r = _channel(key, 10);
    final g = _channel(key, 5);
    final b = _channel(key, 0);
    if (r < minR) minR = r;
    if (r > maxR) maxR = r;
    if (g < minG) minG = g;
    if (g > maxG) maxG = g;
    if (b < minB) minB = b;
    if (b > maxB) maxB = b;
  }
  return (maxR - minR + 1) * (maxG - minG + 1) * (maxB - minB + 1);
}

/// 通道跨度最大的那一维，返回位偏移；并列时红优先、绿次之，与 Palette 一致。
int _widestChannel(List<int> box) {
  var minR = 31, maxR = 0, minG = 31, maxG = 0, minB = 31, maxB = 0;
  for (final key in box) {
    final r = _channel(key, 10);
    final g = _channel(key, 5);
    final b = _channel(key, 0);
    if (r < minR) minR = r;
    if (r > maxR) maxR = r;
    if (g < minG) minG = g;
    if (g > maxG) maxG = g;
    if (b < minB) minB = b;
    if (b > maxB) maxB = b;
  }
  final r = maxR - minR;
  final g = maxG - minG;
  final b = maxB - minB;
  if (r >= g && r >= b) return 10;
  if (g >= r && g >= b) return 5;
  return 0;
}

/// 盒子内按人数加权的平均色，人数为该盒子的总人口。
_PaletteSwatch _averageSwatch(List<int> box, Map<int, int> counts) {
  var population = 0;
  var r = 0;
  var g = 0;
  var b = 0;
  for (final key in box) {
    final n = counts[key]!;
    population += n;
    r += _channel(key, 10) * 8 * n;
    g += _channel(key, 5) * 8 * n;
    b += _channel(key, 0) * 8 * n;
  }
  int avg(int sum) => (sum / population).round();
  return _PaletteSwatch.fromArgb(
    0xFF000000 | (avg(r) << 16) | (avg(g) << 8) | avg(b),
    population,
  );
}
