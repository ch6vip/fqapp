import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/text_replacement_rule.dart';
import 'text_replacement_engine.dart';

class TextReplacementStore extends ChangeNotifier {
  static final instance = TextReplacementStore();
  static const preferenceKey = 'reader_text_replacement_v1';
  TextReplacementSnapshot _snapshot = TextReplacementSnapshot();
  TextReplacementSnapshot get snapshot => _snapshot;
  Listenable get changes => this;
  String? warning;
  Future<void>? _loading;
  bool _loaded = false;
  Future<void>? _writes;

  Future<void> load() async {
    if (_loaded) return;
    try {
      await (_loading ??= _load());
      _loaded = true;
    } finally {
      _loading = null;
    }
  }

  Future<void> _load() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final text = preferences.getString(preferenceKey);
      if (text == null) return;
      final raw = jsonDecode(text);
      if (raw is! Map ||
          raw['schemaVersion'] != 1 ||
          raw['enabled'] is! bool ||
          raw['rules'] is! List) {
        throw const FormatException('替换规则存储格式无效');
      }
      final rules = <TextReplacementRule>[];
      final ids = <String>{};
      for (final record in raw['rules'] as List) {
        try {
          final rule = TextReplacementRule.fromJson(record);
          if (rules.length >= 50 || !ids.add(rule.id)) {
            throw const FormatException();
          }
          rules.add(rule);
        } catch (_) {
          warning = '部分替换规则损坏，已跳过';
        }
      }
      _snapshot = TextReplacementSnapshot(
        enabled: raw['enabled'] as bool,
        rules: rules,
      );
    } catch (_) {
      warning = '无法读取替换规则，已使用默认设置';
    }
  }

  Future<void> save({
    required bool enabled,
    required List<TextReplacementRule> rules,
  }) {
    final immutable = List<TextReplacementRule>.unmodifiable(rules);
    final next = (_writes ?? Future<void>.value()).then((_) async {
      await load();
      await TextReplacementEngine.instance.validateRules(immutable);
      final preferences = await SharedPreferences.getInstance();
      final saved = await preferences.setString(
        preferenceKey,
        jsonEncode({
          'schemaVersion': 1,
          'enabled': enabled,
          'rules': immutable.map((r) => r.toJson()).toList(),
        }),
      );
      if (!saved) throw StateError('替换规则保存失败');
      _snapshot = TextReplacementSnapshot(
        enabled: enabled,
        rules: immutable,
        revision: _snapshot.revision + 1,
      );
      warning = null;
      notifyListeners();
    });
    late final Future<void> tail;
    void clear() {
      if (identical(_writes, tail)) _writes = null;
    }

    tail = next.then<void>(
      (_) => clear(),
      onError: (Object _, StackTrace _) => clear(),
    );
    _writes = tail;
    return next;
  }
}
