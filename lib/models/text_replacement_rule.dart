import 'package:flutter/foundation.dart';

@immutable
class TextReplacementRule {
  const TextReplacementRule({
    required this.id,
    required this.pattern,
    required this.replacement,
    this.isRegex = false,
    this.enabled = true,
  });

  final String id;
  final String pattern;
  final String replacement;
  final bool isRegex;
  final bool enabled;

  Map<String, Object> toJson() => {
    'id': id,
    'pattern': pattern,
    'replacement': replacement,
    'isRegex': isRegex,
    'enabled': enabled,
  };

  factory TextReplacementRule.fromJson(Object? value) {
    if (value is! Map ||
        value['id'] is! String ||
        value['pattern'] is! String ||
        value['replacement'] is! String ||
        value['isRegex'] is! bool ||
        value['enabled'] is! bool) {
      throw const FormatException('替换规则格式无效');
    }
    final rule = TextReplacementRule(
      id: value['id'] as String,
      pattern: value['pattern'] as String,
      replacement: value['replacement'] as String,
      isRegex: value['isRegex'] as bool,
      enabled: value['enabled'] as bool,
    );
    rule.validateStructure();
    return rule;
  }

  void validateStructure() {
    if (id.isEmpty || pattern.isEmpty) {
      throw const FormatException('匹配内容不能为空');
    }
    if (pattern.length > 2048 || replacement.length > 2048) {
      throw const FormatException('匹配内容和替换内容各不能超过 2048 个字符');
    }
    if (RegExp(r'[\r\n\u0085\u2028\u2029]').hasMatch(replacement)) {
      throw const FormatException('替换内容不能包含换行');
    }
  }
}

@immutable
class TextReplacementSnapshot {
  TextReplacementSnapshot({
    this.enabled = false,
    List<TextReplacementRule> rules = const [],
    this.revision = 0,
  }) : rules = List.unmodifiable(rules);

  final bool enabled;
  final List<TextReplacementRule> rules;
  final int revision;
  bool get active => enabled && rules.any((rule) => rule.enabled);
}
