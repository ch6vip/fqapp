import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../models/audio_extra.dart';

/// Presentation-only timeline for the inline TTS strip. Keep the source track
/// intact: the reader and manuscript still address its original cues.
///
/// Official 7.0.9.32: header/m0.x0 measures Chinese/Latin capacity, then
/// subtitle/b2.f splits each sync range and apportions its time by text length.
SubtitleTrack layoutInlineSubtitleLines({
  required SubtitleTrack track,
  required double width,
  required TextStyle style,
  required TextScaler textScaler,
  required TextDirection textDirection,
  Duration duration = Duration.zero,
  Locale? locale,
}) {
  if (track.isEmpty || !width.isFinite || width <= 0) {
    return SubtitleTrack.empty;
  }
  final painter = TextPainter(
    textDirection: textDirection,
    textScaler: textScaler,
    locale: locale,
  );
  double measure(String text) {
    painter.text = TextSpan(text: text, style: style);
    painter.layout();
    return painter.width;
  }

  try {
    // m0 uses screenWidth - 20dp - 2 * fontSize; the strip already has
    // 20dp margins on each side. Clamp for narrow containers/large text.
    final capacityWidth = math.max(
      1.0,
      math.min(width, width + 20 - 2 * textScaler.scale(style.fontSize ?? 16)),
    );
    final chineseCapacity = math.max(
      1,
      (capacityWidth / measure('\u5b57')).floor(),
    );
    final latinCapacity = math.max(1, (capacityWidth / measure('a')).floor());
    final containsChinese = RegExp(r'[\u4e00-\u9fff]');
    // b2.x/w remove punctuation stranded at display-line boundaries. Keep
    // timing offsets in the original text so this cleanup cannot accumulate drift.
    final boundaryPunctuation = RegExp(
      r'^[\uFF0C\u3002\u201C\u201D\uFF1A,:".]+|[\uFF0C\u3002\u201C\u201D\uFF1A,:".]+$',
    );
    final result = <SubtitleCue>[];
    for (var cueIndex = 0; cueIndex < track.cues.length; cueIndex++) {
      final cue = track.cues[cueIndex];
      final chinese = containsChinese.hasMatch(cue.text);
      final capacity = chinese ? chineseCapacity : latinCapacity;
      final characters = cue.text.characters.toList();
      final lines = <({String text, int offset})>[];
      var offset = 0;
      var start = 0;
      while (start < characters.length) {
        var limit = math.min(characters.length, start + capacity);
        for (var i = start; i < limit; i++) {
          if (characters[i].contains('\n') || characters[i].contains('\r')) {
            limit = i;
            break;
          }
        }
        if (limit == start) {
          offset += characters[start++].length;
          continue;
        }
        // Capacity is an estimate for mixed-width glyphs. Fit the real text
        // without cutting surrogate pairs, combining marks or emoji.
        var low = start + 1;
        var high = limit;
        var end = low;
        while (low <= high) {
          final mid = (low + high) >> 1;
          if (measure(characters.sublist(start, mid).join()) <= width) {
            end = mid;
            low = mid + 1;
          } else {
            high = mid - 1;
          }
        }
        if (!chinese && end < characters.length) {
          for (var i = end - 1; i > start; i--) {
            if (characters[i].trim().isEmpty) {
              end = i + 1;
              break;
            }
          }
        }
        final text = characters.sublist(start, end).join();
        lines.add((text: text, offset: offset));
        offset += text.length;
        start = end;
      }
      final endMs = cueIndex + 1 < track.cues.length
          ? track.cues[cueIndex + 1].startMs
          : duration.inMilliseconds > cue.startMs
          ? duration.inMilliseconds
          : track.endMsAt(cueIndex);
      final span = math.max(0, endMs - cue.startMs);
      for (final line in lines) {
        final text = line.text.replaceAll(boundaryPunctuation, '');
        if (text.trim().isEmpty) continue;
        result.add(
          SubtitleCue(
            startMs: cue.startMs + span * line.offset ~/ cue.text.length,
            text: text,
          ),
        );
      }
    }
    return SubtitleTrack(List.unmodifiable(result));
  } finally {
    painter.dispose();
  }
}
