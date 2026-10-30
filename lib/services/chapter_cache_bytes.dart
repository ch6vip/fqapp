import 'dart:convert';

/// UTF-8 byte accounting for cached chapter records.
///
/// Split out of `ChapterCacheStore` to keep that file within the line budget.
/// The rules are unchanged: the persisted measurement is reused when it can be
/// the one this store wrote, otherwise the text is encoded once and memoized
/// for the lifetime of the record object.
class ChapterCacheByteCounter {
  final _measured = Expando<int>();

  /// Texts encoded to measure their size; exposed so a regression test can
  /// assert that a reopened cache reuses the persisted measurement.
  int encodes = 0;

  int bytesOf(Map entry) {
    final text = entry['text'] as String;
    // Reuse the measurement persisted with the record only when it can be the
    // one this store wrote: at least one byte per UTF-16 code unit and at most
    // three. A count equal to the code-unit length is exactly what an
    // all-ASCII text measures; if the text contains any non-ASCII code unit,
    // that count under-reports (each such unit takes at least two bytes), so
    // it is re-measured instead of trusted. Other in-range counts are the
    // values this store itself persists for non-ASCII text, and trusting them
    // is what keeps a restart from re-encoding every chapter.
    final stored = entry['bytes'];
    if (stored is int &&
        stored >= text.length &&
        stored <= text.length * 3 &&
        (stored != text.length || _isAscii(text))) {
      return stored;
    }
    final cached = _measured[entry];
    if (cached != null) return cached;
    encodes++;
    return _measured[entry] = utf8.encode(text).length;
  }

  /// Whether every UTF-16 code unit is ASCII, i.e. one byte in UTF-8.
  static bool _isAscii(String text) {
    for (var index = 0; index < text.length; index++) {
      if (text.codeUnitAt(index) > 0x7F) return false;
    }
    return true;
  }
}
