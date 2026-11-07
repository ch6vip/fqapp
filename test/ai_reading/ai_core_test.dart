import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/ai_reading/ai_apply.dart';
import 'package:fqapp/services/ai_reading/ai_chapter_snapshot.dart';
import 'package:fqapp/services/ai_reading/ai_display_composition.dart';
import 'package:fqapp/services/ai_reading/ai_feedback.dart';
import 'package:fqapp/services/ai_reading/ai_models.dart';
import 'package:fqapp/services/ai_reading/ai_prompt.dart';
import 'package:fqapp/services/ai_reading/ai_protocol.dart';
import 'package:fqapp/services/ai_reading/ai_store.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/text_replacement_engine.dart';

ChapterContent _content(List<String> paragraphs) => ChapterContent(
  blocks: [
    const ChapterParagraph('第一章 标题'),
    for (final text in paragraphs) ChapterParagraph(text),
    const ChapterImage(url: 'https://example.com/a.png'),
  ],
);

void main() {
  const validator = AiValidator();

  test('canonical hash is stable and distinguishes paragraph structure', () {
    final a = AiChapterSnapshotBuilder.fromContent(
      _content(['甲', '乙']),
      '第一章 标题',
    );
    final b = AiChapterSnapshotBuilder.fromContent(
      _content(['甲', '乙']),
      '第一章 标题',
    );
    final c = AiChapterSnapshotBuilder.fromContent(_content(['甲乙']), '第一章 标题');
    expect(a.canonicalHash, b.canonicalHash);
    expect(a.canonicalHash, isNot(c.canonicalHash));
    expect(a.requestText, '甲\n乙');
    expect(a.paragraphStarts, [0, 2]);
    expect(a.canonicalVersion, 1);
  });

  test('images and title do not change the hash', () {
    final a = AiChapterSnapshotBuilder.fromContent(
      _content(['甲', '乙']),
      '第一章 标题',
    );
    final content = ChapterContent(
      blocks: [
        const ChapterParagraph('第一章 标题'),
        const ChapterParagraph('甲'),
        const ChapterImage(url: 'https://example.com/b.png'),
        const ChapterParagraph('乙'),
      ],
    );
    final b = AiChapterSnapshotBuilder.fromContent(content, '第一章 标题');
    expect(a.canonicalHash, b.canonicalHash);
  });

  test('AI off hides AI layer but keeps custom replacement', () {
    const off = AiCompositionConfig(
      aiRequestEnabled: false,
      displayMode: AiDisplayMode.aiOptimized,
    );
    expect(off.effectiveMode, AiDisplayMode.customOnly);
    const original = AiCompositionConfig(
      aiRequestEnabled: false,
      displayMode: AiDisplayMode.original,
    );
    expect(original.effectiveMode, AiDisplayMode.original);
    const on = AiCompositionConfig(
      aiRequestEnabled: true,
      displayMode: AiDisplayMode.aiOptimized,
    );
    expect(on.effectiveMode, AiDisplayMode.aiOptimized);
  });

  test('validator locates a unique single-paragraph edit', () {
    final snapshot = AiChapterSnapshotBuilder.fromContent(
      _content(['天色以晚。', '他说。']),
      '第一章 标题',
    );
    final result = validator.validateContent(
      jsonEncode({
        'edits': [
          {
            'original': '天色以晚。',
            'replacement': '天色已晚。',
            'category': '同音字误用',
            'reason': '「以」应为「已」。',
          },
        ],
      }),
      snapshot,
    );
    expect(result.valid, isTrue);
    expect(result.edits.single.replacement, '天色已晚。');
    expect(result.spans.single.sourceStart, 0);
    expect(result.spans.single.sourceEnd, 5);
  });

  test('validator rejects missing, duplicate, cross-paragraph and overlap', () {
    final snapshot = AiChapterSnapshotBuilder.fromContent(
      _content(['重复', '重复', '甲', '乙']),
      '第一章 标题',
    );
    final result = validator.validateContent(
      jsonEncode({
        'edits': [
          {
            'original': '重复',
            'replacement': '重覆',
            'category': '错别字',
            'reason': '测试',
          },
          {
            'original': '甲\n乙',
            'replacement': '甲乙',
            'category': '标点',
            'reason': '测试',
          },
          {
            'original': '不存在',
            'replacement': '存在',
            'category': '错别字',
            'reason': '测试',
          },
        ],
      }),
      snapshot,
    );
    expect(result.valid, isFalse);
    expect(
      result.errors.map((e) => e.code),
      containsAll([
        'ORIGINAL_NOT_UNIQUE',
        'PARAGRAPH_BREAK',
        'ORIGINAL_NOT_FOUND',
      ]),
    );
  });

  test('validator rejects overlap and unchanged edits', () {
    final snapshot = AiChapterSnapshotBuilder.fromContent(
      _content(['abcdef']),
      '第一章 标题',
    );
    final result = validator.validateContent(
      jsonEncode({
        'edits': [
          {
            'original': 'abc',
            'replacement': 'x',
            'category': '错别字',
            'reason': '测试',
          },
          {
            'original': 'bcd',
            'replacement': 'y',
            'category': '错别字',
            'reason': '测试',
          },
          {
            'original': 'ef',
            'replacement': 'ef',
            'category': '错别字',
            'reason': '测试',
          },
        ],
      }),
      snapshot,
    );
    expect(result.valid, isFalse);
    expect(
      result.errors.map((e) => e.code),
      containsAll(['EDIT_RANGES_OVERLAP', 'UNCHANGED_EDIT']),
    );
  });

  test('pending local-book aggregate rebinds ids without moving offsets', () {
    final content = _content(['天色以晚。', '他说。']);
    final snapshot = AiChapterSnapshotBuilder.fromContent(content, '第一章 标题');
    final now = DateTime(2026, 11, 6);
    final feedback = AiFeedbackCase(
      feedbackId: 'f1',
      bookId: 'local_old',
      chapterId: 'chapter_old',
      canonicalVersion: snapshot.canonicalVersion,
      canonicalHash: snapshot.canonicalHash,
      anchor: const AiSourceAnchor(
        sourceStart: 0,
        sourceEnd: 5,
        paragraphIndex: 0,
        sourceText: '天色以晚。',
      ),
      kind: AiFeedbackKind.good,
      assertion: const AiFeedbackAssertion(type: 'must_equal'),
      comment: '',
      caseRevision: 1,
      history: const [],
      status: AiFeedbackStatus.active,
      protectionEnabled: true,
      createdAt: now,
      updatedAt: now,
    );
    final protection = AiFeedbackProtection(
      protectionId: 'p1',
      sourceFeedbackId: 'f1',
      sourceFeedbackRevision: 1,
      bookId: 'local_old',
      chapterId: 'chapter_old',
      canonicalVersion: snapshot.canonicalVersion,
      canonicalHash: snapshot.canonicalHash,
      sourceStart: 0,
      sourceEnd: 5,
      sourceText: '天色以晚。',
      paragraphIndex: 0,
      policy: AiProtectionPolicy.keepOriginal,
      status: AiProtectionStatus.active,
      createdAt: now,
      updatedAt: now,
    );
    final aggregate = AiFeedbackAggregate(
      bookId: 'local_old',
      chapterId: 'chapter_old',
      canonicalVersion: snapshot.canonicalVersion,
      canonicalHash: snapshot.canonicalHash,
      aggregateRevision: 3,
      cases: [feedback],
      protections: [protection],
      updatedAt: now,
    );
    expect(
      AiFeedbackService.aggregateFitsSnapshot(aggregate, snapshot),
      isTrue,
    );

    final rebound = AiFeedbackService.rebindAggregate(
      aggregate: aggregate,
      bookId: 'local_new',
      chapterId: 'chapter_new',
    );
    expect(rebound.bookId, 'local_new');
    expect(rebound.chapterId, 'chapter_new');
    expect(rebound.cases.single.bookId, 'local_new');
    expect(rebound.cases.single.chapterId, 'chapter_new');
    expect(rebound.cases.single.anchor.sourceStart, 0);
    expect(rebound.protections.single.bookId, 'local_new');
    expect(AiFeedbackService.aggregateFitsSnapshot(rebound, snapshot), isTrue);

    final changed = AiChapterSnapshotBuilder.fromContent(
      _content(['天色已晚。', '他说。']),
      '第一章 标题',
    );
    expect(
      AiFeedbackService.aggregateFitsSnapshot(aggregate, changed),
      isFalse,
    );
  });

  test('apply preserves blocks and maps offsets bi-directionally', () {
    final content = _content(['天色以晚。', '他说。']);
    final snapshot = AiChapterSnapshotBuilder.fromContent(content, '第一章 标题');
    final result = validator.validateContent(
      jsonEncode({
        'edits': [
          {
            'original': '天色以晚。',
            'replacement': '天色已晚。',
            'category': '同音字误用',
            'reason': '「以」应为「已」。',
          },
        ],
      }),
      snapshot,
    );
    final applied = AiApply.apply(
      snapshot: snapshot,
      source: content,
      spans: result.spans,
    );
    expect(applied.content.blocks.length, content.blocks.length);
    expect((applied.content.blocks[1] as ChapterParagraph).text, '天色已晚。');
    expect((applied.content.blocks[2] as ChapterParagraph).text, '他说。');
    final map = applied.paragraphMaps[1]!;
    expect(map.toDisplay(0, bias: TextBoundaryBias.start), 0);
    expect(map.toDisplay(5, bias: TextBoundaryBias.end), 5);
    expect(map.toSource(0, bias: TextBoundaryBias.start), 0);
    expect(map.toSource(5, bias: TextBoundaryBias.end), 5);
    // Points inside a replaced range collapse to the replacement boundary.
    expect(map.toDisplay(2, bias: TextBoundaryBias.start), 0);
    expect(applied.spans.single.replacement, '天色已晚。');
  });
  test('budget projection keeps costs separate per currency', () {
    final projection = AiBudgetProjection(
      bucketDay: '2026-11-06',
      bookId: 'book',
      requestCount: 2,
      taskCount: 1,
      tokenSum: 100,
      unknownUsageCount: 0,
      costMicros: 5,
      currency: 'CNY',
      costsByCurrency: const {'CNY': 5, 'USD': 2},
      reservedRequestCount: 3,
      reservedTaskCount: 1,
      reservedRequestIds: const ['req_1', 'req_2', 'req_3'],
      reservedTaskIds: const ['req_1'],
      reservedRunIds: const {'req_1': 'run_1'},
      updatedAt: DateTime(2026, 11, 6),
    );
    expect(projection.costFor('CNY'), 5);
    expect(projection.totalRequestCount, 5);
    expect(projection.costFor('USD'), 2);
    final decoded = AiBudgetProjection.fromJson(projection.toJson())!;
    expect(decoded.costFor('CNY'), 5);
    expect(decoded.costFor('USD'), 2);
    expect(decoded.totalRequestCount, 5);
    expect(decoded.totalTaskCount, 2);
    expect(decoded.reservedRequestIds, ['req_1', 'req_2', 'req_3']);
    expect(decoded.reservedTaskIds, ['req_1']);
    expect(decoded.reservedRunIds['req_1'], 'run_1');
    final changed = projection.copyWith(requestCount: 9);
    expect(changed.reservedRequestCount, 3);
    expect(changed.reservedTaskCount, 1);
    expect(changed.reservedRequestIds, ['req_1', 'req_2', 'req_3']);
    expect(changed.reservedTaskIds, ['req_1']);
    expect(changed.reservedRunIds['req_1'], 'run_1');
  });

  test('formal cache entry round-trips clear epochs', () {
    final entry = AiFormalCacheEntry(
      bookId: 'book',
      canonicalHash: 'hash',
      canonicalVersion: 1,
      activeRunId: 'run',
      edits: const [],
      status: 'success_empty',
      generation: 3,
      updatedAt: DateTime(2026, 11, 7),
      sourceUtf16Length: 10,
      paragraphBoundaryFingerprint: 'fp',
      integrityHash: 'ih',
      cacheEpoch: 4,
      bookEpoch: 2,
      hashEpoch: 7,
    );
    final decoded = AiFormalCacheEntry.fromJson(entry.toJson())!;
    expect(decoded.cacheEpoch, 4);
    expect(decoded.bookEpoch, 2);
    expect(decoded.hashEpoch, 7);
    expect(decoded.generation, 3);
  });

  test('usage writes fail closed when AI storage is unavailable', () async {
    await expectLater(
      AiStore.instance.putProjection(
        AiBudgetProjection(
          bucketDay: '2026-11-06',
          bookId: null,
          requestCount: 0,
          taskCount: 0,
          tokenSum: 0,
          unknownUsageCount: 0,
          costMicros: 0,
          currency: 'CNY',
          updatedAt: DateTime(2026, 11, 6),
        ),
      ),
      throwsStateError,
    );
  });

  test('cost estimate prices cache and reasoning tokens separately', () {
    final rate = AiRateSnapshot(
      currency: 'CNY',
      inputPerMillionMicros: 2000000,
      outputPerMillionMicros: 8000000,
      cachePerMillionMicros: 500000,
      reasoningPerMillionMicros: 12000000,
      effectiveAt: DateTime(2026),
    );
    final usage = AiUsage(
      promptTokens: 1000000,
      completionTokens: 500000,
      totalTokens: 1500000,
      cachedTokens: 200000,
      reasoningTokens: 100000,
      status: AiUsageStatus.known,
    );
    // 800k input * 2 + 200k cache * .5 + 400k output * 8 + 100k reasoning * 12
    expect(aiEstimateCostMicros(usage, rate), 6100000);
    expect(
      aiEstimateCostMicros(const AiUsage(status: AiUsageStatus.unknown), rate),
      isNull,
    );
  });

  test('edit contract is program-owned and appended to both output modes', () {
    final schema = aiBuildSystemPrompt(
      behaviorPrompt: '自定义行为提示词',
      outputMode: AiOutputMode.jsonSchema,
    );
    expect(schema, contains('自定义行为提示词'));
    expect(schema, contains('original 必须与提供的原文完全一致'));
    expect(schema, isNot(contains(kAiJsonObjectProtocol)));

    final jsonObject = aiBuildSystemPrompt(
      behaviorPrompt: '自定义行为提示词',
      outputMode: AiOutputMode.jsonObject,
    );
    expect(jsonObject, contains('original 必须与提供的原文完全一致'));
    expect(jsonObject, contains(kAiJsonObjectProtocol));
  });

  test('DeepSeek keeps low, high and max reasoning levels', () {
    final profile = AiProviderProfile(
      id: 'deepseek',
      label: 'DeepSeek',
      baseUrl: 'https://api.deepseek.com/v1',
      credentialRef: 'ref',
      outputMode: AiOutputMode.jsonObject,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );
    expect(profile.isDeepSeek, isTrue);
    expect(AiReasoningEffort.parse('max'), AiReasoningEffort.max);
    expect(AiReasoningEffort.parse('xhigh'), AiReasoningEffort.max);
    expect(AiReasoningEffort.max.wire, 'max');
  });
}
