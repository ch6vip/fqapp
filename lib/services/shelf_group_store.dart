// 书架分组仓库：具名分组 + 每条作品的分类归属，持久化为加密 Hive 单文档。
//
// Adapted from Wenku8_Flutter (revision ebcd7f1)
// `local_library_preferences.dart` (organization document, group ids,
// tombstones, limits, merge rules).
//
// Mechanical substitutions:
// - upstream ids are int book ids; fqapp keys are source-qualified
//   `ShelfIdentity.contentKeyOf(item)` strings (`book:123`, `shuqi/book:123`),
//   so two sources with the same numeric id cannot share a group assignment;
// - upstream lives inside one SharedPreferences JSON record next to view
//   preferences; here the organization is its own encrypted Hive box
//   (`shelf_groups_v1`) with a single JSON document, preserving insertion
//   order and making one write atomic;
// - lifecycle hardened for `EncryptedHive` (D-M1): `isReady` is the open box,
//   `reload` only closes its own box, writes are generation-checked, and a
//   corrupt document is quarantined instead of silently overwritten;
// - backup restore only fills gaps (no overwrite, no tombstone propagation),
//   per decisions #8.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive.dart';

import '../models/media_item.dart';
import '../models/shelf_categories.dart';
import '../models/shelf_identity.dart';
import 'app_log.dart';
import 'encrypted_hive.dart';

/// Counts returned by [ShelfGroupStore.mergeBackup].
typedef ShelfGroupMerge = ({int groups, int assignments});

/// Device-local group organization shared by all three shelf tabs.
class ShelfGroupStore implements ShelfCategoryMatcher {
  ShelfGroupStore._();

  static final ShelfGroupStore instance = ShelfGroupStore._();

  static const String boxName = 'shelf_groups_v1';
  static const String documentKey = 'organization_v1';
  static const String all = ShelfCategory.all;
  static const String unfiled = ShelfCategory.unfiled;

  // Structural limits for untrusted (restored) documents.
  static const int hardMaxGroupRecords = 1000;
  static const int hardMaxAssignments = 10000;

  @visibleForTesting
  int maxVisibleGroups = 100;
  @visibleForTesting
  int maxGroupRecords = hardMaxGroupRecords;
  @visibleForTesting
  int maxAssignments = hardMaxAssignments;

  Box<dynamic>? _box;
  final ValueNotifier<int> _revision = ValueNotifier<int>(0);
  final Map<String, Map<String, dynamic>> _groups =
      <String, Map<String, dynamic>>{};
  final Map<String, Map<String, dynamic>> _assignments =
      <String, Map<String, dynamic>>{};
  int _clock = 0;
  int _generation = 0;
  Future<void> _writes = Future<void>.value();

  /// Test seam for the single atomic document write: `null` means the real
  /// `put` + `flush`. Tests inject a failing write to prove that a failed
  /// commit restores the previous in-memory snapshot (D-M2).
  @visibleForTesting
  Future<void> Function(Box<dynamic> box, String encoded)? writeOrganization;

  ValueListenable<int> get listenable => _revision;

  /// Only an open box counts as ready; `Hive.close()` must turn every read
  /// into the safe empty state immediately.
  bool get isReady => _box?.isOpen == true;

  Future<void> init() async {
    if (isReady) return;
    _box = null;
    _groups.clear();
    _assignments.clear();
    _clock = 0;
    _generation++;
    _writes = Future<void>.value();

    final box = await EncryptedHive.openBox<dynamic>(Hive, boxName);
    _box = box;
    final raw = box.get(documentKey);
    if (raw != null) {
      Map<String, dynamic>? valid;
      try {
        valid = validateOrganization(raw is String ? jsonDecode(raw) : raw);
      } on FormatException {
        await _quarantine(box, raw);
      } catch (error, stack) {
        AppLog.w('shelf_group', '读取书架分类失败，按空处理', error: error, stack: stack);
        await _quarantine(box, raw);
      }
      if (valid != null) _adopt(valid);
    }
    _revision.value++;
  }

  /// Closes only this store's box, then reopens it. Never calls `Hive.close`,
  /// which would pull the box out from under other users.
  @visibleForTesting
  Future<void> reload() async {
    try {
      await _writes;
    } catch (_) {
      // A failed write was already reported to its caller.
    }
    final box = _box;
    _box = null;
    if (box != null && box.isOpen) {
      try {
        await box.close();
      } catch (error, stack) {
        AppLog.w('shelf_group', '关闭分类箱失败', error: error, stack: stack);
      }
    }
    await init();
  }

  Future<void> _quarantine(Box<dynamic> box, Object? raw) async {
    try {
      final stamp = DateTime.now().millisecondsSinceEpoch;
      await box.put('$documentKey.corrupt-$stamp', raw);
      await box.flush();
      AppLog.w('shelf_group', '分类文档损坏，原文已保留为 $documentKey.corrupt-$stamp');
    } catch (error, stack) {
      AppLog.w('shelf_group', '分类文档损坏，且副本未能保留', error: error, stack: stack);
    }
  }

  /// Visible groups in insertion order. A closed box reads as "no groups"
  /// instead of serving the last in-memory snapshot.
  Map<String, String> get groups {
    if (!isReady) return const <String, String>{};
    final result = <String, String>{};
    for (final entry in _groups.entries) {
      if (entry.value['deleted'] == true) continue;
      final name = entry.value['name'];
      if (name is String) result[entry.key] = name;
    }
    return Map.unmodifiable(result);
  }

  String groupOf(MediaItem item) =>
      groupOfKey(ShelfIdentity.contentKeyOf(item));

  String groupOfKey(String contentKey) {
    if (!isReady) return unfiled;
    final value = _assignments[contentKey]?['group'];
    return value is String && _hasVisibleGroup(value) ? value : unfiled;
  }

  String nameOf(String category) {
    if (category == all) return '全部书籍';
    if (category == unfiled) return '未分类';
    final author = shelfCategoryAuthor(category);
    if (author != null) return '作者 · $author';
    if (_hasVisibleGroup(category)) {
      return _groups[category]!['name'] as String;
    }
    return '全部书籍';
  }

  bool matches(MediaItem item, String category) =>
      matchesKey(ShelfIdentity.contentKeyOf(item), item.author, category);

  @override
  bool matchesKey(String contentKey, String author, String category) {
    if (category.startsWith(ShelfCategory.authorPrefix)) {
      final name = shelfCategoryAuthor(category);
      return name != null && shelfAuthorName(author) == name;
    }
    return category == all || groupOfKey(contentKey) == category;
  }

  /// Null while the box is not ready, so callers never write a fallback back
  /// into a durable category (D-M4). A ready store returns the category when
  /// it is visible and falls back to 全部 otherwise.
  String? resolveCategory(String category) {
    if (!isReady) return null;
    if (category == all || category == unfiled) return category;
    if (isShelfCategoryWellFormed(category)) {
      if (shelfCategoryAuthor(category) != null) return category;
      if (_hasVisibleGroup(category)) return category;
    }
    return all;
  }

  Future<String> addGroup(String name) {
    final trimmed = name.trim();
    return _organize(() async {
      final box = _requireBox();
      if (trimmed.isEmpty || trimmed.length > 30) {
        throw const FormatException('分类名称需要 1～30 个字');
      }
      if (groups.values.contains(trimmed)) {
        throw const FormatException('已有同名分类');
      }
      if (groups.length >= maxVisibleGroups ||
          _groups.length >= maxGroupRecords) {
        throw const FormatException('分类记录已满，请合并现有分类');
      }
      final next = _copyOrganization(exportOrganization());
      final at = _stamp();
      final id = _newGroupId();
      (next['groups'] as Map<String, dynamic>)[id] = {
        'name': trimmed,
        'at': at,
        'deleted': false,
      };
      await _commit(box, next);
      return id;
    });
  }

  Future<void> renameGroup(String id, String name) {
    final trimmed = name.trim();
    return _organize(() async {
      final box = _requireBox();
      if (!_hasVisibleGroup(id) || trimmed.isEmpty || trimmed.length > 30) {
        throw const FormatException('分类名称需要 1～30 个字');
      }
      if (groups.entries.any(
        (entry) => entry.key != id && entry.value == trimmed,
      )) {
        throw const FormatException('已有同名分类');
      }
      final next = _copyOrganization(exportOrganization());
      (next['groups'] as Map<String, dynamic>)[id] = {
        'name': trimmed,
        'at': _stamp(),
        'deleted': false,
      };
      await _commit(box, next);
    });
  }

  Future<void> removeGroup(String id) {
    return _organize(() async {
      final box = _requireBox();
      if (!_hasVisibleGroup(id)) return;
      final next = _copyOrganization(exportOrganization());
      final current =
          (next['groups'] as Map<String, dynamic>)[id] as Map<String, dynamic>;
      (next['groups'] as Map<String, dynamic>)[id] = {
        ...current,
        'at': _stamp(),
        'deleted': true,
      };
      await _commit(box, next);
    });
  }

  Future<void> assignMany(Iterable<MediaItem> items, String group) =>
      assignKeys(items.map(ShelfIdentity.contentKeyOf), group);

  Future<void> assignKeys(Iterable<String> contentKeys, String group) {
    final keys = contentKeys.toSet();
    return _organize(() async {
      final box = _requireBox();
      if (group != unfiled && !_hasVisibleGroup(group)) {
        throw const FormatException('请选择有效分类');
      }
      for (final key in keys) {
        if (ShelfIdentity.parseContentKey(key) == null) {
          throw const FormatException('作品标识无效');
        }
      }
      if (keys.isEmpty) return;
      final at = _stamp();
      final next = _copyOrganization(exportOrganization());
      final assignments = next['assignments'] as Map<String, dynamic>;
      var changed = false;
      for (final key in keys) {
        final previous = assignments[key];
        if (previous is Map && previous['group'] == group) continue;
        assignments[key] = {'group': group, 'at': at};
        changed = true;
      }
      if (!changed) return;
      if (assignments.length > maxAssignments) {
        throw const FormatException('分类记录已满，请合并现有分类');
      }
      await _commit(box, next);
    });
  }

  Future<void> unassignMany(Iterable<MediaItem> items) =>
      assignKeys(items.map(ShelfIdentity.contentKeyOf), unfiled);

  /// Removes assignments only; the books' own records are untouched.
  Future<void> removeAssignments(Iterable<String> contentKeys) {
    final keys = contentKeys.toSet();
    return _organize(() async {
      final box = _requireBox();
      if (keys.isEmpty) return;
      final next = _copyOrganization(exportOrganization());
      final assignments = next['assignments'] as Map<String, dynamic>;
      var removed = 0;
      for (final key in keys) {
        if (assignments.remove(key) != null) removed++;
      }
      if (removed == 0) return;
      await _commit(box, next);
    });
  }

  /// Full state including tombstones; persistence and tests use this.
  Map<String, dynamic> exportOrganization() => {
    'version': 1,
    'groups': {
      for (final entry in _groups.entries)
        entry.key: Map<String, dynamic>.from(entry.value),
    },
    'assignments': {
      for (final entry in _assignments.entries)
        entry.key: Map<String, dynamic>.from(entry.value),
    },
  };

  /// Visible groups and their assignments only; tombstones and local books are
  /// stripped so a backup carries no device-private path or history.
  Map<String, dynamic> backupOrganization() =>
      portableOrganization(exportOrganization());

  /// Fills gaps only: existing groups/assignments win, tombstones never
  /// resurrect, same-name groups remap onto the local id, local-book keys are
  /// skipped, and an invalid document throws before any write.
  Future<ShelfGroupMerge> mergeBackup(Object? organization) {
    final incoming = validateOrganization(organization);
    return _organize(() async {
      final box = _requireBox();
      final incomingGroups = incoming['groups'] as Map<String, dynamic>;
      final incomingAssignments =
          incoming['assignments'] as Map<String, dynamic>;
      final next = _copyOrganization(exportOrganization());
      final nextGroups = next['groups'] as Map<String, dynamic>;
      final nextAssignments = next['assignments'] as Map<String, dynamic>;
      final remap = <String, String>{};
      final idByName = <String, String>{
        for (final entry in groups.entries) entry.value: entry.key,
      };
      var addedGroups = 0;

      for (final entry in incomingGroups.entries) {
        final id = entry.key;
        final value = Map<String, dynamic>.from(entry.value as Map);
        final at = value['at'] as int;
        _advanceClock(at);
        if (value['deleted'] == true) continue;
        if (nextGroups.containsKey(id)) continue;
        final name = value['name'] as String;
        final existing = idByName[name];
        if (existing != null) {
          remap[id] = existing;
          continue;
        }
        nextGroups[id] = {'name': name, 'at': at, 'deleted': false};
        idByName[name] = id;
        remap[id] = id;
        addedGroups++;
      }

      var addedAssignments = 0;
      for (final entry in incomingAssignments.entries) {
        final key = entry.key;
        final value = Map<String, dynamic>.from(entry.value as Map);
        final at = value['at'] as int;
        _advanceClock(at);
        if (nextAssignments.containsKey(key)) continue;
        if (ShelfIdentity.isLocalContentKey(key)) continue;
        final incomingGroup = value['group'] as String;
        String? group;
        if (incomingGroup == unfiled) {
          group = unfiled;
        } else {
          final remapped = remap[incomingGroup];
          if (remapped != null) {
            group = remapped;
          } else if (_visibleIn(nextGroups, incomingGroup)) {
            group = incomingGroup;
          }
        }
        if (group == null) continue;
        nextAssignments[key] = {'group': group, 'at': at};
        addedAssignments++;
      }

      final visibleGroups = nextGroups.values
          .where((value) => value['deleted'] != true)
          .length;
      if (visibleGroups > maxVisibleGroups ||
          nextGroups.length > maxGroupRecords ||
          nextAssignments.length > maxAssignments) {
        throw const FormatException('分类记录已满，请合并现有分类');
      }

      if (addedGroups == 0 && addedAssignments == 0) {
        await box.flush();
        return (groups: 0, assignments: 0);
      }
      await _commit(box, next);
      return (groups: addedGroups, assignments: addedAssignments);
    });
  }

  @visibleForTesting
  Future<void> whenIdle() async {
    try {
      await _writes;
    } catch (_) {
      // A failed write is reported to its own caller.
    }
  }

  /// Strict validation; throws [FormatException] before any merge write.
  static Map<String, dynamic> validateOrganization(
    Object? input, {
    int maxGroups = hardMaxGroupRecords,
    int maxAssignments = hardMaxAssignments,
  }) {
    if (input is! Map ||
        input['version'] != 1 ||
        input['groups'] is! Map ||
        input['assignments'] is! Map ||
        (input['groups'] as Map).length > maxGroups ||
        (input['assignments'] as Map).length > maxAssignments) {
      throw const FormatException('分类数据格式有误');
    }
    final result = <String, dynamic>{
      'version': 1,
      'groups': <String, dynamic>{},
      'assignments': <String, dynamic>{},
    };
    final groups = result['groups'] as Map<String, dynamic>;
    for (final entry in (input['groups'] as Map).entries) {
      final key = entry.key;
      final value = entry.value;
      if (key is! String ||
          key.length > 80 ||
          !_isGroupId(key) ||
          value is! Map ||
          value['name'] is! String ||
          (value['name'] as String).trim().isEmpty ||
          (value['name'] as String).length > 30 ||
          value['at'] is! int ||
          (value['at'] as int) < 0 ||
          value.containsKey('deleted') && value['deleted'] is! bool) {
        throw const FormatException('分类数据格式有误');
      }
      groups[key] = {
        'name': (value['name'] as String).trim(),
        'at': value['at'] as int,
        'deleted': value['deleted'] == true,
      };
    }
    final assignments = result['assignments'] as Map<String, dynamic>;
    for (final entry in (input['assignments'] as Map).entries) {
      final key = entry.key;
      final value = entry.value;
      if (key is! String ||
          key.length > 256 ||
          ShelfIdentity.parseContentKey(key) == null ||
          value is! Map ||
          value['group'] is! String ||
          (value['group'] as String).length > 80 ||
          !_isAssignmentGroup(value['group'] as String) ||
          value['at'] is! int ||
          (value['at'] as int) < 0) {
        throw const FormatException('分类书籍格式有误');
      }
      assignments[key] = {
        'group': value['group'] as String,
        'at': value['at'] as int,
      };
    }
    return result;
  }

  /// Drops tombstones, local-book assignments, and assignments pointing at
  /// deleted groups. Used by backups so they never carry device-private keys.
  static Map<String, dynamic> portableOrganization(Object? input) {
    final valid = validateOrganization(input);
    final groups = valid['groups'] as Map<String, dynamic>;
    final assignments = valid['assignments'] as Map<String, dynamic>;
    final visibleIds = <String>{
      for (final entry in groups.entries)
        if (entry.value['deleted'] != true) entry.key,
    };
    final portableGroups = <String, dynamic>{
      for (final entry in groups.entries)
        if (visibleIds.contains(entry.key))
          entry.key: Map<String, dynamic>.from(entry.value as Map),
    };
    final portableAssignments = <String, dynamic>{};
    for (final entry in assignments.entries) {
      final key = entry.key;
      if (ShelfIdentity.isLocalContentKey(key)) continue;
      final group = entry.value['group'] as String;
      if (group != unfiled && !visibleIds.contains(group)) continue;
      portableAssignments[key] = Map<String, dynamic>.from(entry.value as Map);
    }
    return {
      'version': 1,
      'groups': portableGroups,
      'assignments': portableAssignments,
    };
  }

  Box<dynamic> _requireBox() {
    final box = _box;
    if (box == null || !box.isOpen) throw StateError('分类尚未初始化');
    return box;
  }

  Future<T> _organize<T>(Future<T> Function() action) {
    final work = _writes.catchError((Object _) {}).then((_) => action());
    _writes = work.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return work;
  }

  Future<void> _commit(Box<dynamic> box, Map<String, dynamic> next) async {
    final previous = exportOrganization();
    final generation = _generation;
    try {
      await (writeOrganization ?? _writeDocument)(box, jsonEncode(next));
    } catch (_) {
      // The visible state never changed before the write; restore the snapshot
      // defensively so a partial Hive update cannot leak through.
      _adopt(previous);
      rethrow;
    }
    if (generation != _generation || !box.isOpen) return;
    _adopt(next);
    _revision.value++;
  }

  static Future<void> _writeDocument(Box<dynamic> box, String encoded) async {
    await box.put(documentKey, encoded);
    await box.flush();
  }

  void _adopt(Map<String, dynamic> valid) {
    final groups = valid['groups'] as Map<String, dynamic>;
    final assignments = valid['assignments'] as Map<String, dynamic>;
    _groups
      ..clear()
      ..addAll(
        groups.map(
          (key, value) =>
              MapEntry(key, Map<String, dynamic>.from(value as Map)),
        ),
      );
    _assignments
      ..clear()
      ..addAll(
        assignments.map(
          (key, value) =>
              MapEntry(key, Map<String, dynamic>.from(value as Map)),
        ),
      );
    for (final value in [..._groups.values, ..._assignments.values]) {
      final at = value['at'];
      if (at is int) _advanceClock(at);
    }
  }

  bool _hasVisibleGroup(String id) {
    if (!isReady) return false;
    final group = _groups[id];
    return group != null && group['deleted'] != true;
  }

  static bool _visibleIn(Map<String, dynamic> groups, String id) {
    final value = groups[id];
    return value is Map && value['deleted'] != true;
  }

  /// A generated group id (`g<base36>-<base36>`), never one of the built-in
  /// `_` categories. Keeps restored documents from exposing a category the UI
  /// can list but `ShelfViewStore.setCategoryOf` would always reject.
  static bool _isGroupId(String value) =>
      !value.startsWith('_') && isShelfCategoryWellFormed(value);

  /// Assignments point at 未分类 or a generated group id. Whether that group
  /// still exists (or is a tombstone) is resolved later by `mergeBackup`.
  static bool _isAssignmentGroup(String value) =>
      value == unfiled || _isGroupId(value);

  void _advanceClock(int at) {
    if (at > _clock) _clock = at;
  }

  int _stamp() {
    final now = DateTime.now().millisecondsSinceEpoch;
    return _clock = now > _clock ? now : _clock + 1;
  }

  String _newGroupId() {
    final random = Random.secure();
    for (var attempt = 0; attempt < 4; attempt++) {
      final id =
          'g${_clock.toRadixString(36)}-'
          '${random.nextInt(0x100000000).toRadixString(36)}'
          '${random.nextInt(0x100000000).toRadixString(36)}';
      if (!_groups.containsKey(id)) return id;
    }
    throw const FormatException('分类标识生成失败，请重试');
  }

  static Map<String, dynamic> _copyOrganization(Map<String, dynamic> value) => {
    'version': 1,
    'groups': {
      for (final entry in (value['groups'] as Map<String, dynamic>).entries)
        entry.key: Map<String, dynamic>.from(entry.value as Map),
    },
    'assignments': {
      for (final entry
          in (value['assignments'] as Map<String, dynamic>).entries)
        entry.key: Map<String, dynamic>.from(entry.value as Map),
    },
  };
}
