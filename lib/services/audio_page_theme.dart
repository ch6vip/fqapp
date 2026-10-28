import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'poster_cache.dart';

/// 听书页的整页配色，由当前书籍封面推出来。
///
/// 官方听书页（`AudioPlayActivity`）不是中性底色：截图 `2.jpg` 里画布是
/// `#F3E9E8`、卡片 `#EBDDDD`、正文 `#4E2E2E`，这套暖棕主色与封面 `我无法收容`
/// 同一色系。仓库里没有任何静态资源能给出这个颜色，所以只能从封面算。
///
/// 纯函数 + 独立小类，方便单测直接喂字节或直接喂主色。
@immutable
class AudioPageTheme {
  /// 页面画布。
  final Color canvas;

  /// 卡片 / 音色片底色。
  final Color card;

  /// 主文字色。
  final Color ink;

  /// 次级文字色。
  final Color muted;

  /// 进度轨、分隔线。
  final Color line;

  /// 进度条已播段与时间药丸底色。
  final Color accent;

  const AudioPageTheme({
    required this.canvas,
    required this.card,
    required this.ink,
    required this.muted,
    required this.line,
    required this.accent,
  });

  /// 封面取色失败、或尚在解码时使用的兜底：官方截图里那一套暖棕。
  static const fallback = AudioPageTheme(
    canvas: Color(0xFFF3E9E8),
    card: Color(0xFFEBDDDD),
    ink: Color(0xFF4E2E2E),
    muted: Color(0xFF816564),
    line: Color(0xFFD9C7C6),
    accent: Color(0xFF532C2F),
  );

  /// OLED 纯黑外观下画布强制纯黑，与书城页的取舍一致。
  AudioPageTheme withOled(bool oled) {
    if (!oled || canvas == const Color(0xFF000000)) return this;
    return AudioPageTheme(
      canvas: const Color(0xFF000000),
      card: card,
      ink: ink,
      muted: muted,
      line: line,
      accent: accent,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AudioPageTheme &&
      other.canvas == canvas &&
      other.card == card &&
      other.ink == ink &&
      other.muted == muted &&
      other.line == line &&
      other.accent == accent;

  @override
  int get hashCode => Object.hash(canvas, card, ink, muted, line, accent);

  /// 深色外观：保留同一色相，压到近黑，避免亮底在夜间刺眼。
  static const fallbackDark = AudioPageTheme(
    canvas: Color(0xFF1B1616),
    card: Color(0xFF241D1D),
    ink: Color(0xFFF0E4E3),
    muted: Color(0xFFA99291),
    line: Color(0xFF3A3030),
    accent: Color(0xFFE8CFCD),
  );

  /// 12 个采样通道（每通道 16 级）里挑出现次数最多的那一桶，作为封面主色。
  ///
  /// 用桶投票而不是算全图均值：封面常有整块留白或大标题，均值会把主色洗成灰。
  static Color dominantFromRgba(Uint8List rgba, {int stride = 1}) {
    final counts = List<int>.filled(4096, 0);
    final sums = List<int>.filled(4096 * 3, 0);
    final step = stride < 1 ? 1 : stride;
    final pixels = rgba.length ~/ 4;
    for (var i = 0; i < pixels; i += step) {
      final o = i * 4;
      final a = rgba[o + 3];
      // 透明像素（PNG 封面常见）不参与投票，否则会投出一桶黑。
      if (a < 128) continue;
      final r = rgba[o];
      final g = rgba[o + 1];
      final b = rgba[o + 2];
      final key = (r >> 4) << 8 | (g >> 4) << 4 | (b >> 4);
      counts[key]++;
      sums[key * 3] += r;
      sums[key * 3 + 1] += g;
      sums[key * 3 + 2] += b;
    }
    var best = -1;
    var bestCount = 0;
    for (var key = 0; key < counts.length; key++) {
      if (counts[key] > bestCount) {
        bestCount = counts[key];
        best = key;
      }
    }
    if (best < 0) return fallback.canvas;
    final n = counts[best];
    return Color.fromARGB(
      255,
      sums[best * 3] ~/ n,
      sums[best * 3 + 1] ~/ n,
      sums[best * 3 + 2] ~/ n,
    );
  }

  /// 复刻官方播放胶囊的取色：只取 AndroidX Palette 某个 swatch 的色相。
  ///
  /// 与 [dominantFromRgba]（听书页整页主题仍在用）互不影响。这里按 Palette
  /// 默认目标的打分规则生成 swatch，再按官方
  /// `PaletteUtils.getColorHByPalette` 的优先级取第一个可用色相：
  /// muted → lightMuted → darkMuted → vibrant → darkVibrant → dominant。
  /// 返回 null 表示封面没有可用颜色，调用方保留兜底色。
  static double? paletteHueFromRgba(Uint8List rgba, {int stride = 1}) {
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

  /// 由封面主色推出整页六档颜色。
  ///
  /// 官方画布 `#F3E9E8` 与封面主色相比是「同色相、压到很高的明度」：把主色
  /// 的色相留在 HSL 里，明度拉到 0.92 附近即得。卡片再压一档，正文反过来
  /// 压到 0.24 得到深棕，保持与官方同一套对比关系。
  factory AudioPageTheme.fromCover(Color dominant, {bool dark = false}) {
    final hsl = HSLColor.fromColor(dominant);
    // 灰阶封面（黑白海报）没有可用色相，退回官方暖棕，否则整页会变灰。
    final saturation = hsl.saturation < 0.12 ? 0.28 : hsl.saturation * 0.5;
    final hue = hsl.saturation < 0.12 ? 9.0 : hsl.hue;
    HSLColor at(double lightness, [double? sat]) => HSLColor.fromAHSL(
      1,
      hue,
      (sat ?? saturation).clamp(0.0, 1.0),
      lightness,
    );
    if (dark) {
      return AudioPageTheme(
        canvas: at(0.11).toColor(),
        card: at(0.16).toColor(),
        ink: at(0.92, saturation * 0.35).toColor(),
        muted: at(0.66, saturation * 0.4).toColor(),
        line: at(0.24).toColor(),
        accent: at(0.82, saturation * 0.6).toColor(),
      );
    }
    return AudioPageTheme(
      canvas: at(0.922).toColor(),
      card: at(0.898).toColor(),
      ink: at(0.24, saturation * 1.35).toColor(),
      muted: at(0.46, saturation * 0.9).toColor(),
      line: at(0.80).toColor(),
      accent: at(0.24, saturation * 1.35).toColor(),
    );
  }
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

/// 把一张封面的字节解成主色。解码放在 isolate 里，避免首帧卡顿。
///
/// 失败一律返回 null，调用方保留 [AudioPageTheme.fallback]。
Future<Color?> coverDominantColor(Uint8List bytes) async {
  final rgba = await _decodeCoverRgba(bytes);
  return rgba == null ? null : AudioPageTheme.dominantFromRgba(rgba);
}

/// 把一张封面的字节解成官方播放胶囊要用的色相。失败返回 null。
Future<double?> coverPaletteHue(Uint8List bytes) async {
  final rgba = await _decodeCoverRgba(bytes);
  return rgba == null ? null : AudioPageTheme.paletteHueFromRgba(rgba);
}

/// 共享的解码路径：缩到长边 64 再读 RGBA。风格与 [dominantFromRgba] 相同，
/// 解码由引擎的异步 codec 完成，不阻塞首帧。
Future<Uint8List?> _decodeCoverRgba(Uint8List bytes) async {
  if (bytes.isEmpty) return null;
  try {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    const target = 64;
    final scale = math.min(
      target / descriptor.width,
      target / descriptor.height,
    );
    final codec = await descriptor.instantiateCodec(
      targetWidth: math.max(1, (descriptor.width * scale).round()),
      targetHeight: math.max(1, (descriptor.height * scale).round()),
    );
    final frame = await codec.getNextFrame();
    final data = await frame.image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    );
    frame.image.dispose();
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();
    return data?.buffer.asUint8List();
  } catch (_) {
    return null;
  }
}

/// 取封面主色：优先读 [PosterCache]，网络失败时返回 null。
Future<Color?> fetchCoverDominant(String url) async {
  final bytes = await _coverBytes(url);
  return bytes == null ? null : coverDominantColor(bytes);
}

/// 取封面 Palette 色相（0..360）：优先读 [PosterCache]，失败时返回 null。
Future<double?> fetchCoverPaletteHue(String url) async {
  final bytes = await _coverBytes(url);
  return bytes == null ? null : coverPaletteHue(bytes);
}

Future<Uint8List?> _coverBytes(String url) async {
  if (url.isEmpty) return null;
  try {
    final file = await PosterCache.instance.getSingleFile(url);
    if (!await file.exists()) return null;
    return await file.readAsBytes();
  } catch (_) {
    return null;
  }
}

/// 让听书页子树读到这套配色的 InheritedWidget。
class AudioPageThemeScope extends InheritedWidget {
  final AudioPageTheme theme;
  final bool oled;

  const AudioPageThemeScope({
    super.key,
    required this.theme,
    this.oled = false,
    required super.child,
  });

  /// 没有外层 scope 时（例如单独渲染某个听书组件）退回兜底色。
  static AudioPageTheme of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<AudioPageThemeScope>();
    return scope?.theme ?? AudioPageTheme.fallback;
  }

  /// OLED 纯黑外观下画布强制纯黑，与书城页的取舍一致。
  static bool oledOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AudioPageThemeScope>()?.oled ??
      false;

  @override
  bool updateShouldNotify(AudioPageThemeScope oldWidget) =>
      theme != oldWidget.theme || oled != oldWidget.oled;
}
