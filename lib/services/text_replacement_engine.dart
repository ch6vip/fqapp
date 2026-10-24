import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math' as math;

import '../models/text_replacement_rule.dart';
import 'chapter_text_formatter.dart';

enum TextBoundaryBias { start, end }

class TextReplacementCancellation {
  bool _cancelled = false;
  void Function()? _onCancel;
  bool get cancelled => _cancelled;
  void cancel() {
    _cancelled = true;
    _onCancel?.call();
  }
}

class _Edit {
  const _Edit(this.start, this.end, this.outputStart, this.outputEnd);
  final int start, end, outputStart, outputEnd;
}

class _MapStage {
  _MapStage(this.edits);
  final List<_Edit> edits;

  int map(int offset, TextBoundaryBias bias, {required bool reverse}) {
    var delta = 0;
    for (final edit in edits) {
      final a = reverse ? edit.outputStart : edit.start;
      final b = reverse ? edit.outputEnd : edit.end;
      final c = reverse ? edit.start : edit.outputStart;
      final d = reverse ? edit.end : edit.outputEnd;
      if (offset < a) return offset + delta;
      if (offset == a) return a == b && bias == TextBoundaryBias.end ? d : c;
      if (offset < b) return bias == TextBoundaryBias.start ? c : d;
      if (offset == b) return d;
      delta = d - b;
    }
    return offset + delta;
  }
}

/// Coordinates are UTF-16 offsets, matching Flutter TextPosition.
class TextOffsetMap {
  TextOffsetMap(this.sourceLength, this.displayLength, this._stages);
  final int sourceLength, displayLength;
  final List<_MapStage> _stages;

  int toSource(int displayOffset, {required TextBoundaryBias bias}) {
    var value = displayOffset.clamp(0, displayLength);
    for (final stage in _stages.reversed) {
      value = stage.map(value, bias, reverse: true);
    }
    return value.clamp(0, sourceLength);
  }

  int toDisplay(int sourceOffset, {required TextBoundaryBias bias}) {
    var value = sourceOffset.clamp(0, sourceLength);
    for (final stage in _stages) {
      value = stage.map(value, bias, reverse: false);
    }
    return value.clamp(0, displayLength);
  }
}

class TextReplacementResult {
  TextReplacementResult({
    required this.source,
    required this.content,
    required this.snapshotRevision,
    this.paragraphMaps = const {},
    this.error,
  });
  final ChapterContent source;
  final ChapterContent content;
  final int snapshotRevision;
  final Map<int, TextOffsetMap> paragraphMaps;
  final String? error;

  List<ChapterBlock> bodyBlocks(String title) {
    final indices = {
      for (var i = 0; i < source.blocks.length; i++) source.blocks[i]: i,
    };
    return [
      for (final block in source.withoutLeadingTitle(title).blocks)
        content.blocks[indices[block]!],
    ];
  }

  bool bodyIsEmpty(String title) {
    final body = source.withoutLeadingTitle(title);
    return body.blocks.isNotEmpty &&
        body.blocks.every((block) {
          if (block is ChapterImage) return false;
          final i = source.blocks.indexOf(block);
          return (content.blocks[i] as ChapterParagraph).text.trim().isEmpty;
        });
  }
}

class TextReplacementEngine {
  TextReplacementEngine({this.timeout = const Duration(seconds: 1)});
  static final instance = TextReplacementEngine();
  final Duration timeout;
  final _cache = <String, TextReplacementResult>{};

  Future<void> validateRule(TextReplacementRule rule) => validateRules([rule]);

  Future<void> validateRules(List<TextReplacementRule> rules) async {
    if (rules.length > 50) throw const FormatException('最多添加 50 条规则');
    final ids = <String>{};
    for (final rule in rules) {
      rule.validateStructure();
      if (!ids.add(rule.id)) throw const FormatException('规则标识重复');
    }
    if (!rules.any((rule) => rule.isRegex)) return;
    await _run(null, '', rules, null);
  }

  Future<TextReplacementResult> transform({
    required ChapterContent source,
    required String chapterTitle,
    required TextReplacementSnapshot snapshot,
    TextReplacementCancellation? cancellation,
  }) async {
    TextReplacementResult original([String? error]) => TextReplacementResult(
      source: source,
      content: source,
      snapshotRevision: snapshot.revision,
      error: error,
    );
    if (!snapshot.active || cancellation?.cancelled == true) return original();
    final key = jsonEncode([
      source.toCacheText(),
      chapterTitle,
      snapshot.revision,
      snapshot.rules.map((r) => r.toJson()).toList(),
    ]);
    final cached = _cache.remove(key);
    if (cached != null) {
      _cache[key] = cached;
      return cached;
    }
    TextReplacementResult result;
    try {
      final changes =
          await _run(source, chapterTitle, snapshot.rules, cancellation)
              as Map<int, (String, TextOffsetMap)>;
      if (cancellation?.cancelled == true) return original();
      result = TextReplacementResult(
        source: source,
        snapshotRevision: snapshot.revision,
        paragraphMaps: Map.unmodifiable(
          changes.map((i, v) => MapEntry(i, v.$2)),
        ),
        content: ChapterContent(
          blocks: [
            for (var i = 0; i < source.blocks.length; i++)
              if (changes[i] case final change?)
                ChapterParagraph(
                  change.$1,
                  paraIndex: (source.blocks[i] as ChapterParagraph).paraIndex,
                  startMs: (source.blocks[i] as ChapterParagraph).startMs,
                  isImageCaption:
                      (source.blocks[i] as ChapterParagraph).isImageCaption,
                )
              else
                source.blocks[i],
          ],
          legacyText: source.legacyText,
          illustrationsChecked: source.illustrationsChecked,
          paragraphIdsChecked: source.paragraphIdsChecked,
          timelineChecked: source.timelineChecked,
        ),
      );
    } catch (error) {
      if (cancellation?.cancelled == true) return original();
      result = original(error is FormatException ? error.message : '$error');
    }
    _cache[key] = result;
    while (_cache.length > 8) {
      _cache.remove(_cache.keys.first);
    }
    return result;
  }

  Future<Object?> _run(
    ChapterContent? source,
    String title,
    List<TextReplacementRule> rules,
    TextReplacementCancellation? cancellation,
  ) async {
    final port = ReceivePort();
    final done = Completer<Object?>();
    // Cancellation can precede Isolate.spawn completing. Register an error
    // listener immediately; awaiting below still receives the same error.
    done.future.ignore();
    Isolate? worker;
    Timer? timer;
    void fail(Object error) {
      if (!done.isCompleted) done.completeError(error);
    }

    final subscription = port.listen((message) {
      if (done.isCompleted) return;
      if (message is Map && message['ready'] == true) {
        timer = Timer(timeout, () => fail(const FormatException('替换规则执行超时')));
      } else if (message is Map && message['error'] is String) {
        fail(FormatException(message['error'] as String));
      } else if (message is Map && message.containsKey('result')) {
        done.complete(message['result']);
      } else {
        fail(const FormatException('替换任务异常退出'));
      }
    });
    cancellation?._onCancel = () => fail(const FormatException('替换任务已取消'));
    try {
      worker = await Isolate.spawn(
        _replacementWorker,
        (port.sendPort, source, title, rules),
        onError: port.sendPort,
        onExit: port.sendPort,
      );
      if (cancellation?.cancelled == true) {
        fail(const FormatException('替换任务已取消'));
      }
      return await done.future;
    } finally {
      timer?.cancel();
      cancellation?._onCancel = null;
      worker?.kill(priority: Isolate.immediate);
      await subscription.cancel();
      port.close();
    }
  }
}

RegExp? _compile(TextReplacementRule rule) {
  rule.validateStructure();
  if (!rule.isRegex) return null;
  final regex = RegExp(rule.pattern, unicode: true);
  // A non-capturing empty alternative exposes groupCount even if the actual
  // pattern cannot match the empty validation sample. It does not renumber groups.
  final groups = RegExp(
    '(?:${rule.pattern})|',
    unicode: true,
  ).firstMatch('')!.groupCount;
  _expandTemplate(rule.replacement, groups, (_) => '');
  return regex;
}

String _expandTemplate(
  String template,
  int groups,
  String Function(int) group, {
  int? maxLength,
}) {
  final out = StringBuffer();
  void append(String value) {
    if (maxLength != null && out.length + value.length > maxLength) {
      throw const FormatException('替换结果超过大小限制');
    }
    out.write(value);
  }

  for (var i = 0; i < template.length; i++) {
    final ch = template[i];
    if (ch != r'$') {
      append(ch);
      continue;
    }
    if (++i >= template.length) throw const FormatException(r'美元符请写为 $$');
    if (template[i] == r'$') {
      append(r'$');
      continue;
    }
    final digit = int.tryParse(template[i]);
    if (digit == null) throw const FormatException(r'替换模板仅支持 $0…$99 和 $$');
    var number = digit;
    final next = i + 1 < template.length ? int.tryParse(template[i + 1]) : null;
    if (next != null) {
      number = number * 10 + next;
      i++;
    }
    if (number > groups) throw const FormatException('替换模板引用了不存在的捕获组');
    append(group(number));
  }
  return out.toString();
}

void _replacementWorker(
  (SendPort, ChapterContent?, String, List<TextReplacementRule>) args,
) {
  final (port, source, title, rules) = args;
  port.send({'ready': true});
  try {
    if (rules.length > 50) throw const FormatException('最多添加 50 条规则');
    final compiled = [for (final rule in rules) (rule, _compile(rule))];
    if (source == null) {
      port.send({'result': null});
      return;
    }
    final body = source.withoutLeadingTitle(title).blocks.toSet();
    final originalLength = source.blocks
        .whereType<ChapterParagraph>()
        .fold<int>(0, (n, p) => n + p.text.length);
    final limit = math.max(65536, originalLength * 4);
    final changes = <int, (String, TextOffsetMap)>{};
    var chapterLength = originalLength;
    var editCount = 0;
    for (var index = 0; index < source.blocks.length; index++) {
      final block = source.blocks[index];
      if (block is! ChapterParagraph ||
          block.isImageCaption ||
          !body.contains(block)) {
        continue;
      }
      var text = block.text;
      final stages = <_MapStage>[];
      for (final (rule, regex) in compiled) {
        if (!rule.enabled) continue;
        final matches =
            regex?.allMatches(text) ?? rule.pattern.allMatches(text);
        final buffer = StringBuffer();
        final edits = <_Edit>[];
        var cursor = 0;
        for (final match in matches) {
          final replacement = regex == null
              ? rule.replacement
              : _expandTemplate(
                  rule.replacement,
                  match.groupCount,
                  (i) => match.group(i) ?? '',
                  maxLength:
                      limit -
                      (chapterLength -
                          text.length +
                          buffer.length +
                          match.start -
                          cursor +
                          text.length -
                          match.end),
                );
          if (RegExp(r'[\r\n\u0085\u2028\u2029]').hasMatch(replacement)) {
            throw const FormatException('替换结果不能包含换行');
          }
          final projected =
              chapterLength -
              text.length +
              buffer.length +
              match.start -
              cursor +
              replacement.length +
              text.length -
              match.end;
          if (projected > limit || ++editCount > 200000) {
            throw const FormatException('替换结果超过大小限制');
          }
          buffer.write(text.substring(cursor, match.start));
          final start = buffer.length;
          buffer.write(replacement);
          edits.add(_Edit(match.start, match.end, start, buffer.length));
          cursor = match.end;
        }
        if (edits.isEmpty) continue;
        buffer.write(text.substring(cursor));
        chapterLength += buffer.length - text.length;
        text = buffer.toString();
        stages.add(_MapStage(edits));
      }
      if (stages.isNotEmpty) {
        changes[index] = (
          text,
          TextOffsetMap(block.text.length, text.length, stages),
        );
      }
    }
    port.send({'result': changes});
  } catch (error) {
    port.send({
      'error': error is FormatException ? error.message : '替换规则无效：$error',
    });
  }
}
