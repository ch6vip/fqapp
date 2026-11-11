import 'dart:convert';

import 'package:characters/characters.dart';

import 'ai_models.dart';

/// Strict parser + locator for the model's edits. All errors are collected; a
/// single invalid edit rejects the whole batch, but the caller still gets the
/// complete error list for the repair turn.
class AiValidator {
  const AiValidator({this.maxEdits = 512, this.maxInputBytes = 128 * 1024});

  final int maxEdits;
  final int maxInputBytes;

  AiValidationResult validateContent(
    String content,
    AiChapterSnapshot snapshot,
  ) {
    if (content.trim().isEmpty) {
      return AiValidationResult.failure(const [
        AiValidationIssue(code: 'RESPONSE_EMPTY'),
      ]);
    }
    dynamic raw;
    try {
      raw = jsonDecode(content);
    } on FormatException catch (error) {
      return AiValidationResult.failure([
        AiValidationIssue(
          code: 'JSON_PARSE_FAILED',
          path: r'$',
          start: error.offset,
        ),
      ]);
    }
    final map = _asMap(raw);
    if (map == null) {
      return AiValidationResult.failure(const [
        AiValidationIssue(code: 'ROOT_NOT_OBJECT'),
      ]);
    }
    final errors = <AiValidationIssue>[];
    for (final key in map.keys) {
      if (key != 'edits') {
        errors.add(AiValidationIssue(code: 'EXTRA_FIELD', path: '\$.$key'));
      }
    }
    if (!map.containsKey('edits')) {
      errors.add(
        const AiValidationIssue(code: 'EDITS_MISSING', path: r'$.edits'),
      );
      return AiValidationResult.failure(errors);
    }
    final rawEdits = map['edits'];
    if (rawEdits is! List) {
      errors.add(
        const AiValidationIssue(code: 'EDITS_NOT_ARRAY', path: r'$.edits'),
      );
      return AiValidationResult.failure(errors);
    }
    if (rawEdits.length > maxEdits) {
      errors.add(
        AiValidationIssue(
          code: 'TOO_MANY_EDITS',
          path: r'$.edits',
          occurrences: rawEdits.length,
        ),
      );
    }

    final edits = <AiRawEdit>[];
    final locations = <_Located>[];
    for (var i = 0; i < rawEdits.length; i++) {
      final item = _asMap(rawEdits[i]);
      final path = '\$.edits[$i]';
      if (item == null) {
        errors.add(
          AiValidationIssue(code: 'EDIT_NOT_OBJECT', path: path, editIndex: i),
        );
        continue;
      }
      for (final key in item.keys) {
        if (!const {
          'original',
          'replacement',
          'category',
          'reason',
        }.contains(key)) {
          errors.add(
            AiValidationIssue(
              code: 'EXTRA_FIELD',
              path: '$path.$key',
              editIndex: i,
            ),
          );
        }
      }
      final parsed = _parseEdit(item, path, i, errors);
      if (parsed == null) continue;
      edits.add(parsed);
      final original = parsed.original;
      if (original.contains('\n')) {
        errors.add(
          AiValidationIssue(
            code: 'PARAGRAPH_BREAK',
            editIndex: i,
            detailKey: 'original contains newline',
          ),
        );
        continue;
      }
      if (!_isWellFormedUtf16(original) ||
          !_isWellFormedUtf16(parsed.replacement)) {
        errors.add(
          AiValidationIssue(code: 'UNICODE_BOUNDARY_INVALID', editIndex: i),
        );
        continue;
      }
      final found = <int>[];
      var from = 0;
      while (true) {
        final at = snapshot.requestText.indexOf(original, from);
        if (at < 0) break;
        found.add(at);
        from = at + 1;
        if (found.length > 64) break;
      }
      if (found.isEmpty) {
        errors.add(
          AiValidationIssue(
            code: 'ORIGINAL_NOT_FOUND',
            editIndex: i,
            detailKey: original.length > 40
                ? original.substring(0, 40)
                : original,
          ),
        );
        continue;
      }
      if (found.length != 1) {
        errors.add(
          AiValidationIssue(
            code: 'ORIGINAL_NOT_UNIQUE',
            editIndex: i,
            occurrences: found.length,
          ),
        );
        continue;
      }
      final start = found.single;
      final end = start + original.length;
      final paragraph = snapshot.paragraphIndexAt(start);
      if (paragraph == null) {
        errors.add(
          AiValidationIssue(
            code: 'EDIT_OUT_OF_RANGE',
            editIndex: i,
            start: start,
            end: end,
          ),
        );
        continue;
      }
      final paragraphEnd = snapshot.paragraphEnd(paragraph);
      if (end > paragraphEnd) {
        errors.add(
          AiValidationIssue(
            code: 'PARAGRAPH_BREAK',
            editIndex: i,
            start: start,
            end: end,
          ),
        );
        continue;
      }
      if (!_isGraphemeBoundary(snapshot.requestText, start) ||
          !_isGraphemeBoundary(snapshot.requestText, end) ||
          !_isGraphemeBoundary(original, 0) ||
          !_isGraphemeBoundary(original, original.length)) {
        errors.add(
          AiValidationIssue(
            code: 'UNICODE_BOUNDARY_INVALID',
            editIndex: i,
            start: start,
            end: end,
          ),
        );
        continue;
      }
      if (original == parsed.replacement) {
        errors.add(
          AiValidationIssue(
            code: 'UNCHANGED_EDIT',
            editIndex: i,
            start: start,
            end: end,
          ),
        );
        continue;
      }
      locations.add(
        _Located(
          editIndex: i,
          start: start,
          end: end,
          paragraphIndex: paragraph,
          blockIndex: snapshot.paragraphBlockIndices[paragraph],
          edit: parsed,
        ),
      );
    }

    locations.sort((a, b) {
      final byStart = a.start.compareTo(b.start);
      return byStart != 0 ? byStart : a.end.compareTo(b.end);
    });
    for (var i = 0; i < locations.length; i++) {
      for (var j = i + 1; j < locations.length; j++) {
        final a = locations[i];
        final b = locations[j];
        if (b.start >= a.end) break;
        final same = a.start == b.start && a.end == b.end;
        errors.add(
          AiValidationIssue(
            code: same ? 'DUPLICATE_EDIT' : 'EDIT_RANGES_OVERLAP',
            editIndices: [a.editIndex, b.editIndex],
            start: b.start,
            end: b.end,
          ),
        );
        if (same && a.edit.replacement != b.edit.replacement) {
          errors.add(
            AiValidationIssue(
              code: 'CONFLICTING_EDIT',
              editIndices: [a.editIndex, b.editIndex],
              start: b.start,
              end: b.end,
            ),
          );
        }
      }
    }

    if (errors.isNotEmpty) return AiValidationResult.failure(errors);

    final spans = _spansFor(snapshot, locations);
    return AiValidationResult.success(
      edits: [for (final location in locations) location.edit],
      spans: spans,
    );
  }

  AiRawEdit? _parseEdit(
    Map<String, dynamic> item,
    String path,
    int index,
    List<AiValidationIssue> errors,
  ) {
    AiValidationIssue issue(String code, [String? suffix]) => AiValidationIssue(
      code: code,
      path: suffix == null ? path : '$path.$suffix',
      editIndex: index,
    );
    final before = errors.length;
    for (final key in const ['original', 'replacement', 'category', 'reason']) {
      if (!item.containsKey(key)) errors.add(issue('FIELD_MISSING', key));
    }
    String? field(String key) {
      final value = item[key];
      if (value == null) return null;
      if (value is! String) {
        errors.add(issue('FIELD_NOT_STRING', key));
        return null;
      }
      return value;
    }

    final original = field('original');
    final replacement = field('replacement');
    final category = field('category');
    final reason = field('reason');
    if (original != null && original.isEmpty) {
      errors.add(issue('ORIGINAL_EMPTY'));
    }
    if (category != null && category.isEmpty) {
      errors.add(issue('CATEGORY_EMPTY'));
    }
    if (reason != null && reason.isEmpty) {
      errors.add(issue('REASON_EMPTY'));
    }
    if (errors.length != before ||
        original == null ||
        replacement == null ||
        category == null ||
        reason == null) {
      return null;
    }
    return AiRawEdit(
      original: original,
      replacement: replacement,
      category: category,
      reason: reason,
    );
  }

  List<AiEditSpan> _spansFor(
    AiChapterSnapshot snapshot,
    List<_Located> locations,
  ) {
    final byParagraph = <int, List<_Located>>{};
    for (final location in locations) {
      byParagraph.putIfAbsent(location.paragraphIndex, () => []).add(location);
    }
    final finalParagraphs = <String>[];
    final paragraphDisplayStarts = <int>[];
    var displayOffset = 0;
    for (var i = 0; i < snapshot.paragraphs.length; i++) {
      final source = snapshot.paragraphs[i];
      final edits = byParagraph[i];
      if (edits == null) {
        paragraphDisplayStarts.add(displayOffset);
        finalParagraphs.add(source);
        displayOffset += source.length + 1;
        continue;
      }
      edits.sort((a, b) => a.start.compareTo(b.start));
      final buffer = StringBuffer();
      var cursor = 0;
      for (final edit in edits) {
        final localStart = edit.start - snapshot.paragraphStart(i);
        final localEnd = edit.end - snapshot.paragraphStart(i);
        buffer
          ..write(source.substring(cursor, localStart))
          ..write(edit.edit.replacement);
        cursor = localEnd;
      }
      buffer.write(source.substring(cursor));
      paragraphDisplayStarts.add(displayOffset);
      finalParagraphs.add(buffer.toString());
      displayOffset += buffer.length + 1;
    }

    final spans = <AiEditSpan>[];
    for (final location in locations) {
      final localSourceStart =
          location.start - snapshot.paragraphStart(location.paragraphIndex);
      final paragraphEdits = byParagraph[location.paragraphIndex]!;
      var delta = 0;
      var displayLocalStart = localSourceStart;
      for (final other in paragraphEdits) {
        if (other.start >= location.start) break;
        delta += other.edit.replacement.length - (other.end - other.start);
      }
      displayLocalStart += delta;
      final displayStart =
          paragraphDisplayStarts[location.paragraphIndex] + displayLocalStart;
      spans.add(
        AiEditSpan(
          editIndex: location.editIndex,
          blockIndex: location.blockIndex,
          paragraphIndex: location.paragraphIndex,
          sourceStart: location.start,
          sourceEnd: location.end,
          displayStart: displayStart,
          displayEnd: displayStart + location.edit.replacement.length,
          original: location.edit.original,
          replacement: location.edit.replacement,
          category: location.edit.category,
          reason: location.edit.reason,
        ),
      );
    }
    spans.sort((a, b) => a.sourceStart.compareTo(b.sourceStart));
    return spans;
  }

  static bool _isGraphemeBoundary(String text, int offset) {
    if (offset <= 0 || offset >= text.length) return true;
    var cursor = 0;
    for (final character in text.characters) {
      if (cursor == offset) return true;
      cursor += character.length;
    }
    return cursor == offset;
  }

  static bool _isWellFormedUtf16(String text) {
    for (var i = 0; i < text.length; i++) {
      final unit = text.codeUnitAt(i);
      if (unit >= 0xD800 && unit <= 0xDBFF) {
        if (i + 1 >= text.length) return false;
        final next = text.codeUnitAt(i + 1);
        if (next < 0xDC00 || next > 0xDFFF) return false;
        i++;
      } else if (unit >= 0xDC00 && unit <= 0xDFFF) {
        return false;
      }
    }
    return true;
  }

  static Map<String, dynamic>? _asMap(Object? value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return value.map((key, value) => MapEntry('$key', value));
    return null;
  }
}

class _Located {
  const _Located({
    required this.editIndex,
    required this.start,
    required this.end,
    required this.paragraphIndex,
    required this.blockIndex,
    required this.edit,
  });

  final int editIndex;
  final int start;
  final int end;
  final int paragraphIndex;
  final int blockIndex;
  final AiRawEdit edit;
}
