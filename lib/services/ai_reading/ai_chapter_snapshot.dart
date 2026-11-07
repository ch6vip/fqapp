import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../chapter_text_formatter.dart';
import 'ai_models.dart';

class AiSnapshotException implements Exception {
  const AiSnapshotException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Builds the immutable `canonical_text_v1` view of one chapter.
///
/// The reader's parser already normalises newlines, NBSP, edge whitespace and
/// empty lines, so paragraphs are the actual rendered body view. Titles and
/// images never enter the hash. An edit is located in [requestText] (paragraphs
/// joined by `\n`) and must stay within a single paragraph.
class AiChapterSnapshotBuilder {
  const AiChapterSnapshotBuilder._();

  static AiChapterSnapshot fromContent(
    ChapterContent content,
    String chapterTitle,
  ) {
    // Keep block indices relative to the original content: AiApply writes
    // edits back by block index, so removing the title must not renumber the
    // remaining blocks.
    final titleKey = chapterTitle.replaceAll(RegExp(r'\s+'), '');
    var titleIndex = -1;
    if (titleKey.isNotEmpty) {
      for (var i = 0; i < content.blocks.length; i++) {
        final block = content.blocks[i];
        if (block is! ChapterParagraph || block.isImageCaption) continue;
        if (block.text.replaceAll(RegExp(r'\s+'), '') == titleKey) {
          titleIndex = i;
        }
        break;
      }
    }

    final paragraphs = <String>[];
    final blockIndices = <int>[];
    for (var i = 0; i < content.blocks.length; i++) {
      if (i == titleIndex) continue;
      final block = content.blocks[i];
      if (block is! ChapterParagraph) continue;
      if (block.text.contains('\n')) {
        throw const AiSnapshotException('章节段落包含换行，无法建立规范正文');
      }
      if (block.text.contains('\uFFFC')) {
        throw const AiSnapshotException('章节正文包含图片占位符，已跳过 AI 校对');
      }
      paragraphs.add(block.text);
      blockIndices.add(i);
    }

    final starts = <int>[];
    var offset = 0;
    for (final paragraph in paragraphs) {
      starts.add(offset);
      offset += paragraph.length + 1;
    }
    final requestText = paragraphs.join('\n');

    final canonicalBytes = _canonicalBytes(paragraphs);
    final canonicalHash = sha256.convert(canonicalBytes).toString();
    final fingerprintBytes = BytesBuilder(copy: false)
      ..add(_u32(paragraphs.length));
    for (final paragraph in paragraphs) {
      fingerprintBytes.add(_u64(utf8.encode(paragraph).length));
    }
    final fingerprint = sha256.convert(fingerprintBytes.takeBytes()).toString();

    return AiChapterSnapshot(
      paragraphs: List.unmodifiable(paragraphs),
      paragraphBlockIndices: List.unmodifiable(blockIndices),
      paragraphStarts: List.unmodifiable(starts),
      requestText: requestText,
      canonicalHash: canonicalHash,
      canonicalVersion: 1,
      sourceUtf16Length: requestText.length,
      paragraphBoundaryFingerprint: fingerprint,
    );
  }

  static Uint8List _canonicalBytes(List<String> paragraphs) {
    final builder = BytesBuilder(copy: false);
    builder.add(utf8.encode('fqapp-ai-paragraphs-v1\u0000'));
    builder.add(_u32(paragraphs.length));
    for (final paragraph in paragraphs) {
      final bytes = utf8.encode(paragraph);
      builder.add(_u64(bytes.length));
      builder.add(bytes);
    }
    return builder.takeBytes();
  }

  static Uint8List _u32(int value) {
    final bytes = ByteData(4)..setUint32(0, value, Endian.big);
    return bytes.buffer.asUint8List();
  }

  static Uint8List _u64(int value) {
    final bytes = ByteData(8)..setUint64(0, value, Endian.big);
    return bytes.buffer.asUint8List();
  }
}
