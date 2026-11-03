/// Balanced quoted passages in UTF-16 display-text coordinates. Unclosed
/// quotes never color the remainder; completed inner pairs still count.
List<(int, int)> readerDialogueRanges(String text) {
  const closing = {
    0x201C: 0x201D,
    0x2018: 0x2019,
    0x300C: 0x300D,
    0x300E: 0x300F,
    0x0022: 0x0022,
  };
  final open = <({int start, int close})>[];
  final pairs = <(int, int)>[];
  var escaped = false;
  for (var index = 0; index < text.length; index++) {
    final unit = text.codeUnitAt(index);
    if (unit == 0x005C) {
      escaped = !escaped;
      continue;
    }
    final escapedQuote = escaped && unit == 0x0022;
    escaped = false;
    if (escapedQuote) continue;
    if (open.isNotEmpty && unit == open.last.close) {
      pairs.add((open.removeLast().start, index + 1));
    } else if (closing[unit] case final end?) {
      open.add((start: index, close: end));
    }
  }
  if (pairs.isEmpty) return const [];
  pairs.sort((a, b) => a.$1.compareTo(b.$1));
  final ranges = <(int, int)>[];
  for (final pair in pairs) {
    if (ranges.isEmpty || pair.$1 > ranges.last.$2) {
      ranges.add(pair);
    } else if (pair.$2 > ranges.last.$2) {
      ranges[ranges.length - 1] = (ranges.last.$1, pair.$2);
    }
  }
  return List.unmodifiable(ranges);
}
