import 'package:flutter/foundation.dart';

/// Session-level quality choice per series, shared by the feed inline
/// player and the full-page player.
///
/// Only the quality NAME is remembered (e.g. `720P`): a variant object
/// carries its own episode's URL, and applying it to another episode would
/// play the wrong stream. Each surface matches the name against the
/// episode's own variants; no match falls back to the default rendition.
///
/// Session-only, like the official client keeping the resolution on the
/// engine for the session: nothing is persisted, and the map dies with
/// the process. Keyed by the series content id (`seriesId ?? id`), which
/// is the feed's pool key and every [PlayerPage] entry point's `bookId`.
class QualityMemory {
  static final Map<String, String> _names = {};

  static String? nameFor(String seriesKey) => _names[seriesKey];

  static void remember(String seriesKey, String name) {
    _names[seriesKey] = name;
  }

  @visibleForTesting
  static void clearForTesting() => _names.clear();
}
