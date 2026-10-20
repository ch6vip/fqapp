import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

abstract interface class SearchHistoryRepository {
  Future<List<String>> load();

  Future<List<String>> add(String query);

  Future<List<String>> remove(String query);

  Future<void> clear();
}

class SearchHistoryStore implements SearchHistoryRepository {
  SearchHistoryStore._();

  static final SearchHistoryStore instance = SearchHistoryStore._();

  static const _key = 'search_history_v1';
  static const maxEntries = 20;
  Future<void> _writes = Future<void>.value();
  Zone _writesZone = Zone.current;

  /// Drops a write chain left over from a different zone.
  ///
  /// A [Future] created in one widget-test zone never completes in another
  /// (each testWidgets test runs in its own FakeAsync zone), so awaiting a
  /// chain from an earlier test would hang [load] forever. In the app the
  /// zone never changes, so this is a no-op there and the chain keeps
  /// serializing concurrent writes.
  void _dropStaleWriteChain() {
    if (!identical(Zone.current, _writesZone)) {
      _writes = Future<void>.value();
      _writesZone = Zone.current;
    }
  }

  @override
  Future<List<String>> load() async {
    _dropStaleWriteChain();
    await _writes;
    return _read();
  }

  Future<List<String>> _read() async {
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.get(_key);
    return normalizeSearchHistory(raw is List ? raw.whereType<String>() : []);
  }

  @override
  Future<List<String>> add(String query) => _serialize(() async {
    final items = mergeSearchHistory(await _read(), query);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setStringList(_key, items);
    return items;
  });

  @override
  Future<List<String>> remove(String query) => _serialize(() async {
    final normalized = normalizeSearchQuery(query).toLowerCase();
    final items = (await _read())
        .where((item) => item.toLowerCase() != normalized)
        .toList(growable: false);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setStringList(_key, items);
    return items;
  });

  @override
  Future<void> clear() => _serialize(() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_key);
  });

  Future<T> _serialize<T>(Future<T> Function() action) {
    _dropStaleWriteChain();
    final operation = _writes.then((_) => action());
    _writes = operation.then<void>((_) {}, onError: (Object _) {});
    return operation;
  }
}

String normalizeSearchQuery(String query) =>
    query.trim().replaceAll(RegExp(r'\s+'), ' ');

List<String> mergeSearchHistory(Iterable<String> current, String query) {
  final normalized = normalizeSearchQuery(query);
  if (normalized.isEmpty) return normalizeSearchHistory(current);
  return normalizeSearchHistory([normalized, ...current]);
}

List<String> normalizeSearchHistory(Iterable<String> values) {
  final output = <String>[];
  final seen = <String>{};
  for (final value in values) {
    final normalized = normalizeSearchQuery(value);
    if (normalized.isEmpty || !seen.add(normalized.toLowerCase())) continue;
    output.add(normalized);
    if (output.length == SearchHistoryStore.maxEntries) break;
  }
  return List.unmodifiable(output);
}
