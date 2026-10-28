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

/// 把一张封面的字节解成主色。解码放在 isolate 里，避免首帧卡顿。
///
/// 失败一律返回 null，调用方保留 [AudioPageTheme.fallback]。
Future<Color?> coverDominantColor(Uint8List bytes) async {
  if (bytes.isEmpty) return null;
  try {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    // 缩到长边 64 再读像素：主色不需要分辨率，小图还能把解码成本压到最低。
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
    if (data == null) return null;
    return AudioPageTheme.dominantFromRgba(data.buffer.asUint8List());
  } catch (_) {
    return null;
  }
}

/// 取封面主色：优先读 [PosterCache]，网络失败时返回 null。
Future<Color?> fetchCoverDominant(String url) async {
  if (url.isEmpty) return null;
  try {
    final file = await PosterCache.instance.getSingleFile(url);
    if (!await file.exists()) return null;
    return await coverDominantColor(await file.readAsBytes());
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
