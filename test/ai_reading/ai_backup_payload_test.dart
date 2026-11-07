import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/ai_reading/ai_backup.dart';
import 'package:fqapp/services/ai_reading/ai_models.dart';

void main() {
  test('AI backup payload round-trips feedback and strips raw trial edits', () {
    final now = DateTime(2026, 11, 5, 12);
    final feedback = AiFeedbackCase(
      feedbackId: 'fb_1',
      bookId: 'book_1',
      chapterId: 'ch_1',
      canonicalVersion: 1,
      canonicalHash: 'hash_1',
      anchor: const AiSourceAnchor(
        sourceStart: 10,
        sourceEnd: 14,
        paragraphIndex: 2,
        sourceText: '天色以晚',
      ),
      kind: AiFeedbackKind.good,
      assertion: const AiFeedbackAssertion(
        type: 'must_equal',
        expectedText: '天色已晚',
      ),
      comment: '同音字',
      caseRevision: 2,
      history: const [],
      status: AiFeedbackStatus.active,
      protectionEnabled: true,
      createdAt: now,
      updatedAt: now,
    );
    final protection = AiFeedbackProtection(
      protectionId: 'pr_1',
      sourceFeedbackId: 'fb_1',
      sourceFeedbackRevision: 2,
      bookId: 'book_1',
      chapterId: 'ch_1',
      canonicalVersion: 1,
      canonicalHash: 'hash_1',
      sourceStart: 10,
      sourceEnd: 14,
      sourceText: '天色以晚',
      paragraphIndex: 2,
      policy: AiProtectionPolicy.keepApprovedEdit,
      status: AiProtectionStatus.active,
      approvedEdit: const AiApprovedEdit(
        original: '天色以晚',
        replacement: '天色已晚',
        sourceStart: 10,
        sourceEnd: 14,
        paragraphIndex: 2,
      ),
      createdAt: now,
      updatedAt: now,
    );
    final payload = AiBackupPayload(
      feedback: [
        AiFeedbackAggregate(
          bookId: 'book_1',
          chapterId: 'ch_1',
          canonicalVersion: 1,
          canonicalHash: 'hash_1',
          aggregateRevision: 3,
          cases: [feedback],
          protections: [protection],
          conflicts: [
            AiRestoreConflict(
              kind: 'case',
              itemId: 'fb_1',
              localJson: '{"v":1}',
              incomingJson: '{"v":2}',
              detectedAt: now,
            ),
          ],
          updatedAt: now,
        ),
      ],
      prompts: const [],
      candidates: const [],
      trials: const [],
      trialResults: [
        AiTrialResultRecord(
          trialId: 'trial_1',
          chapterId: 'ch_1',
          canonicalHash: 'hash_1',
          runId: 'run_1',
          rawValidatedEdits: const [
            AiRawEdit(
              original: '甲',
              replacement: '乙',
              category: '错别字',
              reason: '测试',
            ),
          ],
          validationStatus: 'valid',
          perFeedback: const [],
          createdAt: now,
        ),
      ],
      usage: const [],
      pending: const [],
      createdAt: now,
      globalPrompt: '全局提示词',
      bookPrompts: const {'book_1': '本书提示词'},
      rates: [
        AiRateProfile(
          id: 'rate_1',
          label: 'DeepSeek',
          currency: 'CNY',
          inputPerMillionMicros: 2000000,
          outputPerMillionMicros: 8000000,
          cachePerMillionMicros: 500000,
          reasoningPerMillionMicros: 12000000,
          updatedAt: now,
          providerId: 'deepseek',
          modelId: 'deepseek-flash',
        ),
      ],
    );
    final encoded = payload.toJson();
    final encodedTrial = (encoded['trialResults'] as List).single as Map;
    expect(encodedTrial.containsKey('rawValidatedEdits'), isFalse);
    final restored = AiBackupPayload.fromJson(encoded);
    expect(restored.feedback.single.cases.single.comment, '同音字');
    expect(
      restored.feedback.single.protections.single.approvedEdit!.replacement,
      '天色已晚',
    );
    expect(restored.feedback.single.conflicts.single.itemId, 'fb_1');
    expect(restored.trialResults.single.rawValidatedEdits, isNull);
    expect(restored.globalPrompt, '全局提示词');
    expect(restored.bookPrompts['book_1'], '本书提示词');
    expect(restored.rates.single.modelId, 'deepseek-flash');
  });
  test(
    'corrupt optional sections are rejected instead of silently skipped',
    () {
      for (final key in [
        'trials',
        'trialResults',
        'usage',
        'pending',
        'rates',
      ]) {
        expect(
          () => AiBackupPayload.fromJson({
            'format': 'fqapp.ai-backup',
            'version': 1,
            'feedback': <Object>[],
            'prompts': <Object>[],
            'candidates': <Object>[],
            key: [1],
          }),
          throwsFormatException,
          reason: key,
        );
      }
    },
  );
}
