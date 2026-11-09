import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Wire and storage models for the AI reading layer.
///
/// Everything in this file is plain Dart. The stores keep JSON maps so the
/// schema can evolve without Hive adapters; the reader never sees these
/// objects directly except through [AiEditSpan] and [AiDisplayResult].

enum AiDisplayMode {
  original,
  customOnly,
  aiOptimized;

  static AiDisplayMode parse(Object? value, {AiDisplayMode? fallback}) {
    return switch (value) {
      'original' => AiDisplayMode.original,
      'customOnly' => AiDisplayMode.customOnly,
      'aiOptimized' => AiDisplayMode.aiOptimized,
      _ => fallback ?? AiDisplayMode.aiOptimized,
    };
  }
}

enum AiOutputMode {
  jsonObject,
  jsonSchema;

  static AiOutputMode parse(Object? value, {AiOutputMode? fallback}) {
    return switch (value) {
      'json_schema' || 'jsonSchema' => AiOutputMode.jsonSchema,
      'json_object' || 'jsonObject' => AiOutputMode.jsonObject,
      _ => fallback ?? AiOutputMode.jsonObject,
    };
  }

  String get wire =>
      this == AiOutputMode.jsonSchema ? 'json_schema' : 'json_object';
}

/// Reasoning budget forwarded to providers that support it. `auto` sends no
/// parameter at all, which keeps provider defaults untouched.
enum AiReasoningEffort {
  auto,
  off,
  low,
  medium,
  high,
  max;

  static AiReasoningEffort parse(Object? value, {AiReasoningEffort? fallback}) {
    return switch (value) {
      'auto' => AiReasoningEffort.auto,
      'off' || 'none' || 'disabled' => AiReasoningEffort.off,
      'low' => AiReasoningEffort.low,
      'medium' => AiReasoningEffort.medium,
      'high' => AiReasoningEffort.high,
      'max' || 'xhigh' => AiReasoningEffort.max,
      _ => fallback ?? AiReasoningEffort.auto,
    };
  }

  String get label => switch (this) {
    AiReasoningEffort.auto => '自动',
    AiReasoningEffort.off => '关闭',
    AiReasoningEffort.low => '低',
    AiReasoningEffort.medium => '中',
    AiReasoningEffort.high => '高',
    AiReasoningEffort.max => '最高',
  };

  String get wire => switch (this) {
    AiReasoningEffort.auto => 'auto',
    AiReasoningEffort.off => 'none',
    AiReasoningEffort.low => 'low',
    AiReasoningEffort.medium => 'medium',
    AiReasoningEffort.high => 'high',
    AiReasoningEffort.max => 'max',
  };
}

/// Live progress of one streamed Chat Completions response.
///
/// `estimatedTokens` counts reasoning and content characters with a cheap
/// heuristic until the provider returns the final `usage`; `exact` is true
/// only for that final value. It is display-only and never enters the ledger.
@immutable
class AiStreamProgress {
  const AiStreamProgress({
    this.reasoningChars = 0,
    this.contentChars = 0,
    this.estimatedTokens = 0,
    this.attempt = 1,
    this.exact = false,
    this.notice,
  });

  final int reasoningChars;
  final int contentChars;
  final int estimatedTokens;
  final int attempt;
  final bool exact;
  final String? notice;

  AiStreamProgress copyWith({
    int? reasoningChars,
    int? contentChars,
    int? estimatedTokens,
    int? attempt,
    bool? exact,
    Object? notice = _unset,
  }) => AiStreamProgress(
    reasoningChars: reasoningChars ?? this.reasoningChars,
    contentChars: contentChars ?? this.contentChars,
    estimatedTokens: estimatedTokens ?? this.estimatedTokens,
    attempt: attempt ?? this.attempt,
    exact: exact ?? this.exact,
    notice: identical(notice, _unset) ? this.notice : notice as String?,
  );
}

enum AiRunKind {
  formalFirst,
  formalRefresh,
  formalPrefetch,
  trial,
  promptOptimize,
  probe,
  recovered;

  static AiRunKind parse(Object? value) => switch (value) {
    'formalRefresh' => AiRunKind.formalRefresh,
    'formalPrefetch' => AiRunKind.formalPrefetch,
    'trial' => AiRunKind.trial,
    'promptOptimize' => AiRunKind.promptOptimize,
    'probe' => AiRunKind.probe,
    'recovered' => AiRunKind.recovered,
    _ => AiRunKind.formalFirst,
  };

  String get wire => name;
}

enum AiRunState {
  running,
  validating,
  repairing,
  success,
  failed,
  cancelled,
  storageFailed,
  interrupted;

  static AiRunState parse(Object? value) => values.firstWhere(
    (e) => e.name == value,
    orElse: () => AiRunState.failed,
  );
}

enum AiFeedbackKind {
  good,
  shouldNotChange,
  wrongChange,
  missedChange;

  static AiFeedbackKind parse(Object? value) => switch (value) {
    'good' => AiFeedbackKind.good,
    'shouldNotChange' => AiFeedbackKind.shouldNotChange,
    'wrongChange' => AiFeedbackKind.wrongChange,
    'missedChange' => AiFeedbackKind.missedChange,
    _ => AiFeedbackKind.missedChange,
  };

  String get label => switch (this) {
    AiFeedbackKind.good => '改得好',
    AiFeedbackKind.shouldNotChange => '不该改',
    AiFeedbackKind.wrongChange => '改错了',
    AiFeedbackKind.missedChange => '漏改了',
  };
}

enum AiFeedbackStatus {
  active,
  archived,
  superseded,
  deleted;

  static AiFeedbackStatus parse(Object? value) => values.firstWhere(
    (e) => e.name == value,
    orElse: () => AiFeedbackStatus.active,
  );
}

enum AiProtectionPolicy {
  keepOriginal,
  keepApprovedEdit;

  static AiProtectionPolicy parse(Object? value) => switch (value) {
    'keepApprovedEdit' => AiProtectionPolicy.keepApprovedEdit,
    'keep_original' => AiProtectionPolicy.keepOriginal,
    _ => AiProtectionPolicy.keepOriginal,
  };

  String get wire => this == AiProtectionPolicy.keepApprovedEdit
      ? 'keepApprovedEdit'
      : 'keep_original';
}

enum AiProtectionStatus {
  active,
  revoked,
  superseded;

  static AiProtectionStatus parse(Object? value) => values.firstWhere(
    (e) => e.name == value,
    orElse: () => AiProtectionStatus.revoked,
  );
}

enum AiTrialVerdict {
  passed,
  failed,
  needsReview,
  cannotJudge,
  runFailed;

  static AiTrialVerdict parse(Object? value) => values.firstWhere(
    (e) => e.name == value,
    orElse: () => AiTrialVerdict.cannotJudge,
  );

  String get label => switch (this) {
    AiTrialVerdict.passed => '符合',
    AiTrialVerdict.failed => '未符合',
    AiTrialVerdict.needsReview => '待人工确认',
    AiTrialVerdict.cannotJudge => '无法判断',
    AiTrialVerdict.runFailed => '运行失败',
  };
}

enum AiUsageStatus {
  known,
  partial,
  unknown;

  static AiUsageStatus parse(Object? value) => values.firstWhere(
    (e) => e.name == value,
    orElse: () => AiUsageStatus.unknown,
  );
}

/// One edit exactly as the model returned it. `category`/`reason` are display
/// metadata only and never participate in locating or composing an edit.
@immutable
class AiRawEdit {
  const AiRawEdit({
    required this.original,
    required this.replacement,
    required this.category,
    required this.reason,
  });

  final String original;
  final String replacement;
  final String category;
  final String reason;

  Map<String, dynamic> toJson() => {
    'original': original,
    'replacement': replacement,
    'category': category,
    'reason': reason,
  };

  AiRawEdit copyWith({
    String? original,
    String? replacement,
    String? category,
    String? reason,
  }) => AiRawEdit(
    original: original ?? this.original,
    replacement: replacement ?? this.replacement,
    category: category ?? this.category,
    reason: reason ?? this.reason,
  );
}

/// A validated, located edit. Source coordinates are half-open UTF-16 offsets
/// in the chapter's `requestText` (paragraphs joined by `\n`). Display
/// coordinates are half-open offsets in the composed body text, including the
/// structural newlines between paragraphs.
@immutable
class AiEditSpan {
  const AiEditSpan({
    required this.editIndex,
    required this.blockIndex,
    required this.paragraphIndex,
    required this.sourceStart,
    required this.sourceEnd,
    required this.displayStart,
    required this.displayEnd,
    required this.original,
    required this.replacement,
    required this.category,
    required this.reason,
    this.approved = false,
  });

  final int editIndex;
  final int blockIndex;
  final int paragraphIndex;
  final int sourceStart;
  final int sourceEnd;
  final int displayStart;
  final int displayEnd;
  final String original;
  final String replacement;
  final String category;
  final String reason;

  /// True when this span was replayed from a `keep_approved_edit` protection
  /// rather than returned by the current model run.
  final bool approved;

  int get sourceLength => sourceEnd - sourceStart;
  int get displayLength => displayEnd - displayStart;
  bool get isDeletion => replacement.isEmpty;

  Map<String, dynamic> toJson() => {
    'editIndex': editIndex,
    'blockIndex': blockIndex,
    'paragraphIndex': paragraphIndex,
    'sourceStart': sourceStart,
    'sourceEnd': sourceEnd,
    'displayStart': displayStart,
    'displayEnd': displayEnd,
    'original': original,
    'replacement': replacement,
    'category': category,
    'reason': reason,
    if (approved) 'approved': true,
  };

  static AiEditSpan? fromJson(Object? raw) {
    final map = _mapOrNull(raw);
    if (map == null) return null;
    final sourceStart = _intOrNull(map['sourceStart']);
    final sourceEnd = _intOrNull(map['sourceEnd']);
    final original = map['original'];
    final replacement = map['replacement'];
    if (sourceStart == null || sourceEnd == null || sourceEnd < sourceStart) {
      return null;
    }
    if (original is! String || replacement is! String) return null;
    return AiEditSpan(
      editIndex: _intOrNull(map['editIndex']) ?? 0,
      blockIndex: _intOrNull(map['blockIndex']) ?? 0,
      paragraphIndex: _intOrNull(map['paragraphIndex']) ?? 0,
      sourceStart: sourceStart,
      sourceEnd: sourceEnd,
      displayStart: _intOrNull(map['displayStart']) ?? sourceStart,
      displayEnd: _intOrNull(map['displayEnd']) ?? sourceEnd,
      original: original,
      replacement: replacement,
      category: map['category'] is String ? map['category'] as String : '其他',
      reason: map['reason'] is String ? map['reason'] as String : '',
      approved: map['approved'] == true,
    );
  }

  AiEditSpan copyWith({int? displayStart, int? displayEnd, bool? approved}) =>
      AiEditSpan(
        editIndex: editIndex,
        blockIndex: blockIndex,
        paragraphIndex: paragraphIndex,
        sourceStart: sourceStart,
        sourceEnd: sourceEnd,
        displayStart: displayStart ?? this.displayStart,
        displayEnd: displayEnd ?? this.displayEnd,
        original: original,
        replacement: replacement,
        category: category,
        reason: reason,
        approved: approved ?? this.approved,
      );
}

@immutable
class AiChapterSnapshot {
  const AiChapterSnapshot({
    required this.paragraphs,
    required this.paragraphBlockIndices,
    required this.paragraphStarts,
    required this.requestText,
    required this.canonicalHash,
    required this.canonicalVersion,
    required this.sourceUtf16Length,
    required this.paragraphBoundaryFingerprint,
  });

  final List<String> paragraphs;

  /// Index into the original [ChapterContent.blocks] for each paragraph.
  final List<int> paragraphBlockIndices;

  /// Start offset of each paragraph in [requestText].
  final List<int> paragraphStarts;

  final String requestText;
  final String canonicalHash;
  final int canonicalVersion;
  final int sourceUtf16Length;

  /// Stable digest of the paragraph count and per-paragraph UTF-16 lengths.
  /// It lets a reader reject a snapshot whose boundaries changed even if the
  /// hash unexpectedly collides.
  final String paragraphBoundaryFingerprint;

  int get paragraphCount => paragraphs.length;

  int? paragraphIndexAt(int offset, {bool endBias = false}) {
    if (paragraphs.isEmpty) return null;
    final target = offset.clamp(0, requestText.length);
    for (var i = 0; i < paragraphs.length; i++) {
      final start = paragraphStarts[i];
      final end = start + paragraphs[i].length;
      if (target >= start && (target < end || (endBias && target == end))) {
        return i;
      }
    }
    if (target == requestText.length && paragraphs.isNotEmpty) {
      return paragraphs.length - 1;
    }
    return null;
  }

  int paragraphStart(int index) => paragraphStarts[index];
  int paragraphEnd(int index) =>
      paragraphStarts[index] + paragraphs[index].length;

  int localOffset(int paragraphIndex, int absoluteOffset) =>
      absoluteOffset - paragraphStarts[paragraphIndex];
}

@immutable
class AiValidationIssue {
  const AiValidationIssue({
    required this.code,
    this.path,
    this.editIndex,
    this.editIndices = const [],
    this.start,
    this.end,
    this.occurrences,
    this.detailKey,
  });

  final String code;
  final String? path;
  final int? editIndex;
  final List<int> editIndices;
  final int? start;
  final int? end;
  final int? occurrences;
  final String? detailKey;

  Map<String, dynamic> toJson() => {
    'code': code,
    if (path != null) 'path': path,
    if (editIndex != null) 'editIndex': editIndex,
    if (editIndices.isNotEmpty) 'editIndices': editIndices,
    if (start != null) 'start': start,
    if (end != null) 'end': end,
    if (occurrences != null) 'occurrences': occurrences,
    if (detailKey != null) 'detailKey': detailKey,
  };
}

@immutable
class AiValidationResult {
  const AiValidationResult._({
    required this.valid,
    required this.edits,
    required this.spans,
    required this.errors,
  });

  factory AiValidationResult.success({
    required List<AiRawEdit> edits,
    required List<AiEditSpan> spans,
  }) => AiValidationResult._(
    valid: true,
    edits: List.unmodifiable(edits),
    spans: List.unmodifiable(spans),
    errors: const [],
  );

  factory AiValidationResult.failure(List<AiValidationIssue> errors) =>
      AiValidationResult._(
        valid: false,
        edits: const [],
        spans: const [],
        errors: List.unmodifiable(errors),
      );

  final bool valid;
  final List<AiRawEdit> edits;
  final List<AiEditSpan> spans;
  final List<AiValidationIssue> errors;

  bool get hasErrors => errors.isNotEmpty;
}

@immutable
class AiProviderProfile {
  const AiProviderProfile({
    required this.id,
    required this.label,
    required this.baseUrl,
    required this.credentialRef,
    required this.outputMode,
    this.temperature = 0.2,
    this.reasoningEffort = AiReasoningEffort.auto,
    this.models = const [],
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String label;
  final String baseUrl;
  final String credentialRef;
  final AiOutputMode outputMode;
  final double temperature;
  final AiReasoningEffort reasoningEffort;
  final List<String> models;
  final DateTime createdAt;
  final DateTime updatedAt;

  String get host {
    final uri = Uri.tryParse(baseUrl);
    return uri?.host ?? baseUrl;
  }

  bool get isDeepSeek =>
      id == 'deepseek' || host.toLowerCase().endsWith('deepseek.com');

  AiProviderProfile copyWith({
    String? label,
    String? baseUrl,
    String? credentialRef,
    AiOutputMode? outputMode,
    double? temperature,
    AiReasoningEffort? reasoningEffort,
    List<String>? models,
    DateTime? updatedAt,
  }) => AiProviderProfile(
    id: id,
    label: label ?? this.label,
    baseUrl: baseUrl ?? this.baseUrl,
    credentialRef: credentialRef ?? this.credentialRef,
    outputMode: outputMode ?? this.outputMode,
    temperature: temperature ?? this.temperature,
    reasoningEffort: reasoningEffort ?? this.reasoningEffort,
    models: models ?? this.models,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    'baseUrl': baseUrl,
    'credentialRef': credentialRef,
    'outputMode': outputMode.wire,
    'temperature': temperature,
    'reasoningEffort': reasoningEffort.name,
    'models': models,
    'createdAt': createdAt.millisecondsSinceEpoch,
    'updatedAt': updatedAt.millisecondsSinceEpoch,
  };

  static AiProviderProfile? fromJson(Object? raw) {
    final map = _mapOrNull(raw);
    if (map == null) return null;
    final id = map['id'];
    final baseUrl = map['baseUrl'];
    final credentialRef = map['credentialRef'];
    if (id is! String || baseUrl is! String || credentialRef is! String) {
      return null;
    }
    return AiProviderProfile(
      id: id,
      label: map['label'] is String ? map['label'] as String : '自定义提供商',
      baseUrl: baseUrl,
      credentialRef: credentialRef,
      outputMode: AiOutputMode.parse(map['outputMode']),
      temperature: _double(map['temperature'], 0.2, 0, 2),
      reasoningEffort: AiReasoningEffort.parse(map['reasoningEffort']),
      models: _stringList(map['models']),
      createdAt: _date(map['createdAt']) ?? DateTime.now(),
      updatedAt: _date(map['updatedAt']) ?? DateTime.now(),
    );
  }
}

@immutable
class AiModelCapability {
  const AiModelCapability({
    required this.key,
    required this.providerId,
    required this.endpoint,
    required this.apiFamily,
    required this.modelId,
    required this.outputMode,
    required this.schemaStrict,
    required this.schemaProjectionHash,
    required this.verifiedAt,
    required this.ok,
    this.detail,
  });

  final String key;
  final String providerId;
  final String endpoint;
  final String apiFamily;
  final String modelId;
  final AiOutputMode outputMode;
  final bool schemaStrict;
  final String schemaProjectionHash;
  final DateTime verifiedAt;
  final bool ok;
  final String? detail;

  Map<String, dynamic> toJson() => {
    'key': key,
    'providerId': providerId,
    'endpoint': endpoint,
    'apiFamily': apiFamily,
    'modelId': modelId,
    'outputMode': outputMode.wire,
    'schemaStrict': schemaStrict,
    'schemaProjectionHash': schemaProjectionHash,
    'verifiedAt': verifiedAt.millisecondsSinceEpoch,
    'ok': ok,
    if (detail != null) 'detail': detail,
  };

  static AiModelCapability? fromJson(Object? raw) {
    final map = _mapOrNull(raw);
    if (map == null) return null;
    final key = map['key'];
    if (key is! String) return null;
    return AiModelCapability(
      key: key,
      providerId: map['providerId'] is String
          ? map['providerId'] as String
          : '',
      endpoint: map['endpoint'] is String ? map['endpoint'] as String : '',
      apiFamily: map['apiFamily'] is String
          ? map['apiFamily'] as String
          : 'chat.completions',
      modelId: map['modelId'] is String ? map['modelId'] as String : '',
      outputMode: AiOutputMode.parse(map['outputMode']),
      schemaStrict: map['schemaStrict'] == true,
      schemaProjectionHash: map['schemaProjectionHash'] is String
          ? map['schemaProjectionHash'] as String
          : '',
      verifiedAt: _date(map['verifiedAt']) ?? DateTime.now(),
      ok: map['ok'] == true,
      detail: map['detail'] is String ? map['detail'] as String : null,
    );
  }
}

@immutable
class AiDeviceSettings {
  const AiDeviceSettings({
    this.cloudConsent = false,
    this.deviceDisabled = false,
  });

  final bool cloudConsent;
  final bool deviceDisabled;

  Map<String, dynamic> toJson() => {
    'cloudConsent': cloudConsent,
    'deviceDisabled': deviceDisabled,
  };

  AiDeviceSettings copyWith({bool? cloudConsent, bool? deviceDisabled}) =>
      AiDeviceSettings(
        cloudConsent: cloudConsent ?? this.cloudConsent,
        deviceDisabled: deviceDisabled ?? this.deviceDisabled,
      );

  static AiDeviceSettings fromJson(Object? raw) {
    final map = _mapOrNull(raw);
    return AiDeviceSettings(
      cloudConsent: map?['cloudConsent'] == true,
      deviceDisabled: map?['deviceDisabled'] == true,
    );
  }
}

@immutable
class AiGlobalSettings {
  const AiGlobalSettings({
    this.enabled = false,
    this.providerId,
    this.modelId,
    this.displayMode = AiDisplayMode.aiOptimized,
    this.behaviorPrompt,
    this.restoreCensoredWords = false,
    this.requestTimeoutSeconds = 120,
    this.contentRepairLimit = 2,
    this.transportRetryLimit = 1,
    this.prefetchEnabled = true,
    this.prefetchTriggerRatio = 0.5,
    this.maxPrefetchChapters = 1,
    this.prefetchConcurrency = 1,
    this.dailyTokenLimit = 1000000,
    this.bookTokenLimit = 200000,
    this.dailyRequestLimit = 200,
    this.bookRequestLimit = 60,
    this.dailyCostLimit,
    this.bookCostLimit,
    this.costCurrency = 'CNY',
    this.markStyle = 'dotted',
    this.usagePriceProfile,
  });

  final bool enabled;
  final String? providerId;
  final String? modelId;
  final AiDisplayMode displayMode;
  final String? behaviorPrompt;
  final bool restoreCensoredWords;
  final int requestTimeoutSeconds;
  final int contentRepairLimit;
  final int transportRetryLimit;
  final bool prefetchEnabled;
  final double prefetchTriggerRatio;
  final int maxPrefetchChapters;
  final int prefetchConcurrency;
  final int dailyTokenLimit;
  final int bookTokenLimit;
  final int dailyRequestLimit;
  final int bookRequestLimit;
  final double? dailyCostLimit;
  final double? bookCostLimit;
  final String costCurrency;
  final String markStyle;
  final String? usagePriceProfile;

  AiGlobalSettings copyWith({
    bool? enabled,
    Object? providerId = _unset,
    Object? modelId = _unset,
    AiDisplayMode? displayMode,
    Object? behaviorPrompt = _unset,
    bool? restoreCensoredWords,
    int? requestTimeoutSeconds,
    int? contentRepairLimit,
    int? transportRetryLimit,
    bool? prefetchEnabled,
    double? prefetchTriggerRatio,
    int? maxPrefetchChapters,
    int? prefetchConcurrency,
    int? dailyTokenLimit,
    int? bookTokenLimit,
    int? dailyRequestLimit,
    int? bookRequestLimit,
    Object? dailyCostLimit = _unset,
    Object? bookCostLimit = _unset,
    String? costCurrency,
    String? markStyle,
    Object? usagePriceProfile = _unset,
  }) => AiGlobalSettings(
    enabled: enabled ?? this.enabled,
    restoreCensoredWords: restoreCensoredWords ?? this.restoreCensoredWords,
    providerId: identical(providerId, _unset)
        ? this.providerId
        : providerId as String?,
    modelId: identical(modelId, _unset) ? this.modelId : modelId as String?,
    displayMode: displayMode ?? this.displayMode,
    behaviorPrompt: identical(behaviorPrompt, _unset)
        ? this.behaviorPrompt
        : behaviorPrompt as String?,
    requestTimeoutSeconds: requestTimeoutSeconds ?? this.requestTimeoutSeconds,
    contentRepairLimit: contentRepairLimit ?? this.contentRepairLimit,
    transportRetryLimit: transportRetryLimit ?? this.transportRetryLimit,
    prefetchEnabled: prefetchEnabled ?? this.prefetchEnabled,
    prefetchTriggerRatio: prefetchTriggerRatio ?? this.prefetchTriggerRatio,
    maxPrefetchChapters: maxPrefetchChapters ?? this.maxPrefetchChapters,
    prefetchConcurrency: prefetchConcurrency ?? this.prefetchConcurrency,
    dailyTokenLimit: dailyTokenLimit ?? this.dailyTokenLimit,
    bookTokenLimit: bookTokenLimit ?? this.bookTokenLimit,
    dailyRequestLimit: dailyRequestLimit ?? this.dailyRequestLimit,
    bookRequestLimit: bookRequestLimit ?? this.bookRequestLimit,
    dailyCostLimit: identical(dailyCostLimit, _unset)
        ? this.dailyCostLimit
        : dailyCostLimit as double?,
    bookCostLimit: identical(bookCostLimit, _unset)
        ? this.bookCostLimit
        : bookCostLimit as double?,
    costCurrency: costCurrency ?? this.costCurrency,
    markStyle: markStyle ?? this.markStyle,
    usagePriceProfile: identical(usagePriceProfile, _unset)
        ? this.usagePriceProfile
        : usagePriceProfile as String?,
  );

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'providerId': providerId,
    'modelId': modelId,
    'displayMode': displayMode.name,
    'behaviorPrompt': behaviorPrompt,
    'restoreCensoredWords': restoreCensoredWords,
    'requestTimeoutSeconds': requestTimeoutSeconds,
    'contentRepairLimit': contentRepairLimit,
    'transportRetryLimit': transportRetryLimit,
    'prefetchEnabled': prefetchEnabled,
    'prefetchTriggerRatio': prefetchTriggerRatio,
    'maxPrefetchChapters': maxPrefetchChapters,
    'prefetchConcurrency': prefetchConcurrency,
    'dailyTokenLimit': dailyTokenLimit,
    'bookTokenLimit': bookTokenLimit,
    'dailyRequestLimit': dailyRequestLimit,
    'bookRequestLimit': bookRequestLimit,
    'dailyCostLimit': dailyCostLimit,
    'bookCostLimit': bookCostLimit,
    'costCurrency': costCurrency,
    'markStyle': markStyle,
    'usagePriceProfile': usagePriceProfile,
  };

  factory AiGlobalSettings.fromJson(Object? raw) {
    final map = _mapOrNull(raw) ?? const {};
    return AiGlobalSettings(
      enabled: map['enabled'] == true,
      restoreCensoredWords: map['restoreCensoredWords'] == true,
      providerId: map['providerId'] is String
          ? map['providerId'] as String
          : null,
      modelId: map['modelId'] is String ? map['modelId'] as String : null,
      displayMode: AiDisplayMode.parse(map['displayMode']),
      behaviorPrompt: map['behaviorPrompt'] is String
          ? map['behaviorPrompt'] as String
          : null,
      requestTimeoutSeconds: _int(map['requestTimeoutSeconds'], 120, 10, 600),
      contentRepairLimit: _int(map['contentRepairLimit'], 2, 0, 3),
      transportRetryLimit: _int(map['transportRetryLimit'], 1, 0, 2),
      prefetchEnabled: map['prefetchEnabled'] != false,
      prefetchTriggerRatio: _double(map['prefetchTriggerRatio'], 0.5, 0, 0.9),
      maxPrefetchChapters: _int(map['maxPrefetchChapters'], 1, 1, 3),
      prefetchConcurrency: 1,
      dailyTokenLimit: _int(map['dailyTokenLimit'], 1000000, 1000, 100000000),
      bookTokenLimit: _int(map['bookTokenLimit'], 200000, 1000, 100000000),
      dailyRequestLimit: _int(map['dailyRequestLimit'], 200, 1, 100000),
      bookRequestLimit: _int(map['bookRequestLimit'], 60, 1, 100000),
      dailyCostLimit: _doubleOrNull(map['dailyCostLimit']),
      bookCostLimit: _doubleOrNull(map['bookCostLimit']),
      costCurrency: map['costCurrency'] is String
          ? map['costCurrency'] as String
          : 'CNY',
      markStyle: map['markStyle'] is String
          ? map['markStyle'] as String
          : 'dotted',
      usagePriceProfile: map['usagePriceProfile'] is String
          ? map['usagePriceProfile'] as String
          : null,
    );
  }
}

@immutable
class AiEffectiveValue<T> {
  const AiEffectiveValue(this.value, this.source);
  final T value;
  final String source;
}

@immutable
class AiEffectiveSettings {
  const AiEffectiveSettings({
    required this.global,
    required this.enabled,
    required this.displayMode,
    required this.providerId,
    required this.modelId,
    required this.behaviorPrompt,
    required this.prefetchEnabled,
    required this.prefetchTriggerRatio,
    required this.maxPrefetchChapters,
    required this.requestTimeoutSeconds,
    required this.contentRepairLimit,
    required this.transportRetryLimit,
    required this.dailyTokenLimit,
    required this.bookTokenLimit,
    required this.dailyRequestLimit,
    required this.bookRequestLimit,
    required this.dailyCostLimit,
    required this.bookCostLimit,
    required this.markStyle,
    required this.sources,
  });

  final AiGlobalSettings global;
  final bool enabled;
  final AiDisplayMode displayMode;
  final String? providerId;
  final String? modelId;
  final String? behaviorPrompt;
  final bool prefetchEnabled;
  final double prefetchTriggerRatio;
  final int maxPrefetchChapters;
  final int requestTimeoutSeconds;
  final int contentRepairLimit;
  final int transportRetryLimit;
  final int dailyTokenLimit;
  final int bookTokenLimit;
  final int dailyRequestLimit;
  final int bookRequestLimit;
  final double? dailyCostLimit;
  final double? bookCostLimit;
  final String markStyle;
  final Map<String, String> sources;
}

@immutable
class AiSourceAnchor {
  const AiSourceAnchor({
    required this.sourceStart,
    required this.sourceEnd,
    required this.paragraphIndex,
    required this.sourceText,
    this.contextBefore = '',
    this.contextAfter = '',
  });

  final int sourceStart;
  final int sourceEnd;
  final int paragraphIndex;
  final String sourceText;
  final String contextBefore;
  final String contextAfter;

  int get length => sourceEnd - sourceStart;

  Map<String, dynamic> toJson() => {
    'sourceStart': sourceStart,
    'sourceEnd': sourceEnd,
    'paragraphIndex': paragraphIndex,
    'sourceText': sourceText,
    if (contextBefore.isNotEmpty) 'contextBefore': contextBefore,
    if (contextAfter.isNotEmpty) 'contextAfter': contextAfter,
  };

  static AiSourceAnchor? fromJson(Object? raw) {
    final map = _mapOrNull(raw);
    if (map == null) return null;
    final start = _intOrNull(map['sourceStart']);
    final end = _intOrNull(map['sourceEnd']);
    final sourceText = map['sourceText'];
    if (start == null || end == null || end < start || sourceText is! String) {
      return null;
    }
    return AiSourceAnchor(
      sourceStart: start,
      sourceEnd: end,
      paragraphIndex: _intOrNull(map['paragraphIndex']) ?? 0,
      sourceText: sourceText,
      contextBefore: map['contextBefore'] is String
          ? map['contextBefore'] as String
          : '',
      contextAfter: map['contextAfter'] is String
          ? map['contextAfter'] as String
          : '',
    );
  }
}

@immutable
class AiFeedbackAssertion {
  const AiFeedbackAssertion({
    required this.type,
    this.expectedText,
    this.forbiddenReplacement,
    this.assertionAnchorStart,
    this.assertionAnchorEnd,
  });

  final String type;
  final String? expectedText;
  final String? forbiddenReplacement;
  final int? assertionAnchorStart;
  final int? assertionAnchorEnd;

  Map<String, dynamic> toJson() => {
    'type': type,
    if (expectedText != null) 'expectedText': expectedText,
    if (forbiddenReplacement != null)
      'forbiddenReplacement': forbiddenReplacement,
    if (assertionAnchorStart != null)
      'assertionAnchorStart': assertionAnchorStart,
    if (assertionAnchorEnd != null) 'assertionAnchorEnd': assertionAnchorEnd,
  };

  static AiFeedbackAssertion fromJson(Object? raw) {
    final map = _mapOrNull(raw) ?? const {};
    return AiFeedbackAssertion(
      type: map['type'] is String ? map['type'] as String : 'manual_review',
      expectedText: map['expectedText'] is String
          ? map['expectedText'] as String
          : null,
      forbiddenReplacement: map['forbiddenReplacement'] is String
          ? map['forbiddenReplacement'] as String
          : null,
      assertionAnchorStart: _intOrNull(map['assertionAnchorStart']),
      assertionAnchorEnd: _intOrNull(map['assertionAnchorEnd']),
    );
  }
}

@immutable
class AiFeedbackHistoryEntry {
  const AiFeedbackHistoryEntry({
    required this.revision,
    required this.kind,
    required this.assertion,
    required this.comment,
    required this.status,
    required this.changedAt,
  });

  final int revision;
  final AiFeedbackKind kind;
  final AiFeedbackAssertion assertion;
  final String comment;
  final AiFeedbackStatus status;
  final DateTime changedAt;

  Map<String, dynamic> toJson() => {
    'revision': revision,
    'kind': kind.name,
    'assertion': assertion.toJson(),
    'comment': comment,
    'status': status.name,
    'changedAt': changedAt.millisecondsSinceEpoch,
  };

  static AiFeedbackHistoryEntry? fromJson(Object? raw) {
    final map = _mapOrNull(raw);
    if (map == null) return null;
    return AiFeedbackHistoryEntry(
      revision: _intOrNull(map['revision']) ?? 1,
      kind: AiFeedbackKind.parse(map['kind']),
      assertion: AiFeedbackAssertion.fromJson(map['assertion']),
      comment: map['comment'] is String ? map['comment'] as String : '',
      status: AiFeedbackStatus.parse(map['status']),
      changedAt: _date(map['changedAt']) ?? DateTime.now(),
    );
  }
}

@immutable
class AiFeedbackCase {
  const AiFeedbackCase({
    required this.feedbackId,
    required this.bookId,
    required this.chapterId,
    required this.canonicalVersion,
    required this.canonicalHash,
    required this.anchor,
    required this.kind,
    required this.assertion,
    required this.comment,
    required this.caseRevision,
    required this.history,
    required this.status,
    required this.protectionEnabled,
    required this.createdAt,
    required this.updatedAt,
    this.originalObservation,
  });

  final String feedbackId;
  final String bookId;
  final String chapterId;
  final int canonicalVersion;
  final String canonicalHash;
  final AiSourceAnchor anchor;
  final AiFeedbackKind kind;
  final AiFeedbackAssertion assertion;
  final String comment;
  final int caseRevision;
  final List<AiFeedbackHistoryEntry> history;
  final AiFeedbackStatus status;
  final bool protectionEnabled;
  final DateTime createdAt;
  final DateTime updatedAt;
  final Map<String, dynamic>? originalObservation;

  bool get isActive => status == AiFeedbackStatus.active;

  AiFeedbackCase copyWith({
    AiFeedbackKind? kind,
    AiFeedbackAssertion? assertion,
    String? comment,
    int? caseRevision,
    List<AiFeedbackHistoryEntry>? history,
    AiFeedbackStatus? status,
    bool? protectionEnabled,
    DateTime? updatedAt,
    Map<String, dynamic>? originalObservation,
  }) => AiFeedbackCase(
    feedbackId: feedbackId,
    bookId: bookId,
    chapterId: chapterId,
    canonicalVersion: canonicalVersion,
    canonicalHash: canonicalHash,
    anchor: anchor,
    kind: kind ?? this.kind,
    assertion: assertion ?? this.assertion,
    comment: comment ?? this.comment,
    caseRevision: caseRevision ?? this.caseRevision,
    history: history ?? this.history,
    status: status ?? this.status,
    protectionEnabled: protectionEnabled ?? this.protectionEnabled,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    originalObservation: originalObservation ?? this.originalObservation,
  );

  Map<String, dynamic> toJson() => {
    'feedbackId': feedbackId,
    'bookId': bookId,
    'chapterId': chapterId,
    'canonicalVersion': canonicalVersion,
    'canonicalHash': canonicalHash,
    'anchor': anchor.toJson(),
    'kind': kind.name,
    'assertion': assertion.toJson(),
    'comment': comment,
    'caseRevision': caseRevision,
    'history': history.map((e) => e.toJson()).toList(),
    'status': status.name,
    'protectionEnabled': protectionEnabled,
    'createdAt': createdAt.millisecondsSinceEpoch,
    'updatedAt': updatedAt.millisecondsSinceEpoch,
    if (originalObservation != null) 'originalObservation': originalObservation,
  };

  static AiFeedbackCase? fromJson(Object? raw) {
    final map = _mapOrNull(raw);
    if (map == null) return null;
    final feedbackId = map['feedbackId'];
    final bookId = map['bookId'];
    final chapterId = map['chapterId'];
    final anchor = AiSourceAnchor.fromJson(map['anchor']);
    if (feedbackId is! String ||
        bookId is! String ||
        chapterId is! String ||
        anchor == null) {
      return null;
    }
    return AiFeedbackCase(
      feedbackId: feedbackId,
      bookId: bookId,
      chapterId: chapterId,
      canonicalVersion: _intOrNull(map['canonicalVersion']) ?? 1,
      canonicalHash: map['canonicalHash'] is String
          ? map['canonicalHash'] as String
          : '',
      anchor: anchor,
      kind: AiFeedbackKind.parse(map['kind']),
      assertion: AiFeedbackAssertion.fromJson(map['assertion']),
      comment: map['comment'] is String ? map['comment'] as String : '',
      caseRevision: _intOrNull(map['caseRevision']) ?? 1,
      history: [
        for (final entry in (map['history'] as List? ?? const []))
          ?AiFeedbackHistoryEntry.fromJson(entry),
      ],
      status: AiFeedbackStatus.parse(map['status']),
      protectionEnabled: map['protectionEnabled'] != false,
      createdAt: _date(map['createdAt']) ?? DateTime.now(),
      updatedAt: _date(map['updatedAt']) ?? DateTime.now(),
      originalObservation: _mapOrNull(map['originalObservation']),
    );
  }
}

@immutable
class AiApprovedEdit {
  const AiApprovedEdit({
    required this.original,
    required this.replacement,
    required this.sourceStart,
    required this.sourceEnd,
    required this.paragraphIndex,
    this.category,
    this.reason,
    this.sourceRunId,
    this.sourceEditIndex,
  });

  final String original;
  final String replacement;
  final int sourceStart;
  final int sourceEnd;
  final int paragraphIndex;
  final String? category;
  final String? reason;
  final String? sourceRunId;
  final int? sourceEditIndex;

  Map<String, dynamic> toJson() => {
    'original': original,
    'replacement': replacement,
    'sourceStart': sourceStart,
    'sourceEnd': sourceEnd,
    'paragraphIndex': paragraphIndex,
    if (category != null) 'category': category,
    if (reason != null) 'reason': reason,
    if (sourceRunId != null) 'sourceRunId': sourceRunId,
    if (sourceEditIndex != null) 'sourceEditIndex': sourceEditIndex,
  };

  static AiApprovedEdit? fromJson(Object? raw) {
    final map = _mapOrNull(raw);
    if (map == null) return null;
    final original = map['original'];
    final replacement = map['replacement'];
    final start = _intOrNull(map['sourceStart']);
    final end = _intOrNull(map['sourceEnd']);
    if (original is! String ||
        replacement is! String ||
        start == null ||
        end == null) {
      return null;
    }
    return AiApprovedEdit(
      original: original,
      replacement: replacement,
      sourceStart: start,
      sourceEnd: end,
      paragraphIndex: _intOrNull(map['paragraphIndex']) ?? 0,
      sourceRunId: map['sourceRunId'] is String
          ? map['sourceRunId'] as String
          : null,
      sourceEditIndex: _intOrNull(map['sourceEditIndex']),
    );
  }
}

@immutable
class AiFeedbackProtection {
  const AiFeedbackProtection({
    required this.protectionId,
    required this.sourceFeedbackId,
    required this.sourceFeedbackRevision,
    required this.bookId,
    required this.chapterId,
    required this.canonicalVersion,
    required this.canonicalHash,
    required this.sourceStart,
    required this.sourceEnd,
    required this.sourceText,
    required this.paragraphIndex,
    required this.policy,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.approvedEdit,
    this.supersededByFeedbackId,
  });

  final String protectionId;
  final String sourceFeedbackId;
  final int sourceFeedbackRevision;
  final String bookId;
  final String chapterId;
  final int canonicalVersion;
  final String canonicalHash;
  final int sourceStart;
  final int sourceEnd;
  final String sourceText;
  final int paragraphIndex;
  final AiProtectionPolicy policy;
  final AiProtectionStatus status;
  final DateTime createdAt;
  final DateTime updatedAt;
  final AiApprovedEdit? approvedEdit;
  final String? supersededByFeedbackId;

  bool get isActive => status == AiProtectionStatus.active;
  bool get isKeepOriginal => policy == AiProtectionPolicy.keepOriginal;
  bool get isKeepApproved => policy == AiProtectionPolicy.keepApprovedEdit;

  bool intersects(int start, int end) => sourceStart < end && start < sourceEnd;

  AiFeedbackProtection copyWith({
    AiProtectionStatus? status,
    String? supersededByFeedbackId,
    DateTime? updatedAt,
    AiApprovedEdit? approvedEdit,
  }) => AiFeedbackProtection(
    protectionId: protectionId,
    sourceFeedbackId: sourceFeedbackId,
    sourceFeedbackRevision: sourceFeedbackRevision,
    bookId: bookId,
    chapterId: chapterId,
    canonicalVersion: canonicalVersion,
    canonicalHash: canonicalHash,
    sourceStart: sourceStart,
    sourceEnd: sourceEnd,
    sourceText: sourceText,
    paragraphIndex: paragraphIndex,
    policy: policy,
    status: status ?? this.status,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    approvedEdit: approvedEdit ?? this.approvedEdit,
    supersededByFeedbackId:
        supersededByFeedbackId ?? this.supersededByFeedbackId,
  );

  Map<String, dynamic> toJson() => {
    'protectionId': protectionId,
    'sourceFeedbackId': sourceFeedbackId,
    'sourceFeedbackRevision': sourceFeedbackRevision,
    'bookId': bookId,
    'chapterId': chapterId,
    'canonicalVersion': canonicalVersion,
    'canonicalHash': canonicalHash,
    'sourceStart': sourceStart,
    'sourceEnd': sourceEnd,
    'sourceText': sourceText,
    'paragraphIndex': paragraphIndex,
    'policy': policy.wire,
    'status': status.name,
    'createdAt': createdAt.millisecondsSinceEpoch,
    'updatedAt': updatedAt.millisecondsSinceEpoch,
    if (approvedEdit != null) 'approvedEdit': approvedEdit!.toJson(),
    if (supersededByFeedbackId != null)
      'supersededByFeedbackId': supersededByFeedbackId,
  };

  static AiFeedbackProtection? fromJson(Object? raw) {
    final map = _mapOrNull(raw);
    if (map == null) return null;
    final id = map['protectionId'];
    final sourceFeedbackId = map['sourceFeedbackId'];
    final start = _intOrNull(map['sourceStart']);
    final end = _intOrNull(map['sourceEnd']);
    if (id is! String ||
        sourceFeedbackId is! String ||
        start == null ||
        end == null) {
      return null;
    }
    return AiFeedbackProtection(
      protectionId: id,
      sourceFeedbackId: sourceFeedbackId,
      sourceFeedbackRevision: _intOrNull(map['sourceFeedbackRevision']) ?? 1,
      bookId: map['bookId'] is String ? map['bookId'] as String : '',
      chapterId: map['chapterId'] is String ? map['chapterId'] as String : '',
      canonicalVersion: _intOrNull(map['canonicalVersion']) ?? 1,
      canonicalHash: map['canonicalHash'] is String
          ? map['canonicalHash'] as String
          : '',
      sourceStart: start,
      sourceEnd: end,
      sourceText: map['sourceText'] is String
          ? map['sourceText'] as String
          : '',
      paragraphIndex: _intOrNull(map['paragraphIndex']) ?? 0,
      policy: AiProtectionPolicy.parse(map['policy']),
      status: AiProtectionStatus.parse(map['status']),
      createdAt: _date(map['createdAt']) ?? DateTime.now(),
      updatedAt: _date(map['updatedAt']) ?? DateTime.now(),
      approvedEdit: AiApprovedEdit.fromJson(map['approvedEdit']),
      supersededByFeedbackId: map['supersededByFeedbackId'] is String
          ? map['supersededByFeedbackId'] as String
          : null,
    );
  }
}

@immutable
class AiRestoreConflict {
  const AiRestoreConflict({
    required this.kind,
    required this.itemId,
    required this.localJson,
    required this.incomingJson,
    required this.detectedAt,
  });

  /// `case` or `protection`.
  final String kind;
  final String itemId;
  final String localJson;
  final String incomingJson;
  final DateTime detectedAt;

  String get signature => jsonEncode([kind, itemId, localJson, incomingJson]);

  Map<String, dynamic> toJson() => {
    'kind': kind,
    'itemId': itemId,
    'localJson': localJson,
    'incomingJson': incomingJson,
    'detectedAt': detectedAt.millisecondsSinceEpoch,
  };

  static AiRestoreConflict? fromJson(Object? raw) {
    final map = _mapOrNull(raw);
    if (map == null) return null;
    final kind = map['kind'];
    final itemId = map['itemId'];
    if (kind is! String || itemId is! String) return null;
    return AiRestoreConflict(
      kind: kind,
      itemId: itemId,
      localJson: map['localJson'] is String ? map['localJson'] as String : '',
      incomingJson: map['incomingJson'] is String
          ? map['incomingJson'] as String
          : '',
      detectedAt: _date(map['detectedAt']) ?? DateTime.now(),
    );
  }
}

@immutable
class AiFeedbackAggregate {
  const AiFeedbackAggregate({
    required this.bookId,
    required this.chapterId,
    required this.canonicalVersion,
    required this.canonicalHash,
    required this.aggregateRevision,
    required this.cases,
    required this.protections,
    required this.updatedAt,
    this.conflicts = const [],
  });

  final String bookId;
  final String chapterId;
  final int canonicalVersion;
  final String canonicalHash;
  final int aggregateRevision;
  final List<AiFeedbackCase> cases;
  final List<AiFeedbackProtection> protections;
  final DateTime updatedAt;

  /// Parallel branches discovered while restoring a backup. They are kept
  /// intact instead of letting a clock decide which device wins.
  final List<AiRestoreConflict> conflicts;

  List<AiFeedbackProtection> get activeProtections =>
      protections.where((p) => p.isActive).toList(growable: false);

  List<AiFeedbackCase> get activeCases =>
      cases.where((c) => c.isActive).toList(growable: false);

  String get key =>
      jsonEncode([bookId, chapterId, canonicalVersion, canonicalHash]);

  Map<String, dynamic> toJson() => {
    'bookId': bookId,
    'chapterId': chapterId,
    'canonicalVersion': canonicalVersion,
    'canonicalHash': canonicalHash,
    'aggregateRevision': aggregateRevision,
    'cases': cases.map((e) => e.toJson()).toList(),
    'protections': protections.map((e) => e.toJson()).toList(),
    'conflicts': conflicts.map((e) => e.toJson()).toList(),
    'updatedAt': updatedAt.millisecondsSinceEpoch,
  };

  static AiFeedbackAggregate? fromJson(Object? raw) {
    final map = _mapOrNull(raw);
    if (map == null) return null;
    final bookId = map['bookId'];
    final chapterId = map['chapterId'];
    if (bookId is! String || chapterId is! String) return null;
    return AiFeedbackAggregate(
      bookId: bookId,
      chapterId: chapterId,
      canonicalVersion: _intOrNull(map['canonicalVersion']) ?? 1,
      canonicalHash: map['canonicalHash'] is String
          ? map['canonicalHash'] as String
          : '',
      aggregateRevision: _intOrNull(map['aggregateRevision']) ?? 0,
      cases: [
        for (final entry in (map['cases'] as List? ?? const []))
          ?AiFeedbackCase.fromJson(entry),
      ],
      protections: [
        for (final entry in (map['protections'] as List? ?? const []))
          ?AiFeedbackProtection.fromJson(entry),
      ],
      conflicts: [
        for (final entry in (map['conflicts'] as List? ?? const []))
          ?AiRestoreConflict.fromJson(entry),
      ],
      updatedAt: _date(map['updatedAt']) ?? DateTime.now(),
    );
  }
}

enum AiChapterCheckState {
  unchecked,
  running,
  checked,
  failed;

  static AiChapterCheckState parse(Object? value) => switch (value) {
    'running' => AiChapterCheckState.running,
    'checked' => AiChapterCheckState.checked,
    'failed' => AiChapterCheckState.failed,
    _ => AiChapterCheckState.unchecked,
  };
}

/// Lightweight per-chapter status index for the reader directory.
///
/// The formal cache is keyed by content hash and cannot be queried by chapter
/// id, so this record remembers the last known state for each chapter. The
/// chapter version is a cheap stale check; opening the chapter still verifies
/// the real canonical hash before using a cached result.
@immutable
class AiChapterCheckStatus {
  const AiChapterCheckStatus({
    required this.bookId,
    required this.chapterId,
    required this.chapterVersion,
    required this.state,
    required this.updatedAt,
    this.canonicalHash,
    this.errorCode,
  });

  final String bookId;
  final String chapterId;
  final String chapterVersion;
  final AiChapterCheckState state;
  final DateTime updatedAt;
  final String? canonicalHash;
  final String? errorCode;

  AiChapterCheckStatus copyWith({
    String? chapterVersion,
    AiChapterCheckState? state,
    DateTime? updatedAt,
    Object? canonicalHash = _unset,
    Object? errorCode = _unset,
  }) => AiChapterCheckStatus(
    bookId: bookId,
    chapterId: chapterId,
    chapterVersion: chapterVersion ?? this.chapterVersion,
    state: state ?? this.state,
    updatedAt: updatedAt ?? this.updatedAt,
    canonicalHash: identical(canonicalHash, _unset)
        ? this.canonicalHash
        : canonicalHash as String?,
    errorCode: identical(errorCode, _unset)
        ? this.errorCode
        : errorCode as String?,
  );

  Map<String, dynamic> toJson() => {
    'bookId': bookId,
    'chapterId': chapterId,
    'chapterVersion': chapterVersion,
    'state': state.name,
    'updatedAt': updatedAt.millisecondsSinceEpoch,
    if (canonicalHash != null) 'canonicalHash': canonicalHash,
    if (errorCode != null) 'errorCode': errorCode,
  };

  static AiChapterCheckStatus? fromJson(Object? raw) {
    final map = _mapOrNull(raw);
    if (map == null) return null;
    final bookId = map['bookId'];
    final chapterId = map['chapterId'];
    if (bookId is! String || chapterId is! String) return null;
    return AiChapterCheckStatus(
      bookId: bookId,
      chapterId: chapterId,
      chapterVersion: map['chapterVersion'] is String
          ? map['chapterVersion'] as String
          : '',
      state: AiChapterCheckState.parse(map['state']),
      updatedAt: _date(map['updatedAt']) ?? DateTime.now(),
      canonicalHash: map['canonicalHash'] is String
          ? map['canonicalHash'] as String
          : null,
      errorCode: map['errorCode'] is String ? map['errorCode'] as String : null,
    );
  }
}

/// Stable fingerprint for the formal edit payload. It detects cache damage;
/// it is not a security signature.
String aiIntegrityHash(String value) {
  var hash = 2166136261;
  for (final code in value.codeUnits) {
    hash ^= code;
    hash = (hash * 16777619) & 0x7fffffff;
  }
  return hash.toRadixString(16);
}

@immutable
class AiFormalCacheEntry {
  const AiFormalCacheEntry({
    required this.bookId,
    required this.canonicalHash,
    required this.canonicalVersion,
    required this.activeRunId,
    required this.edits,
    required this.status,
    required this.generation,
    required this.updatedAt,
    required this.sourceUtf16Length,
    required this.paragraphBoundaryFingerprint,
    required this.integrityHash,
    this.model,
    this.promptHash,
    this.errorCodes = const [],
    this.cacheEpoch = 0,
    this.bookEpoch = 0,
    this.hashEpoch = 0,
  });

  final String bookId;
  final String canonicalHash;
  final int canonicalVersion;
  final String activeRunId;
  final List<AiRawEdit> edits;
  final String status; // success | success_empty
  final int generation;
  final DateTime updatedAt;
  final int sourceUtf16Length;
  final String paragraphBoundaryFingerprint;
  final String integrityHash;
  final String? model;
  final String? promptHash;
  final List<String> errorCodes;
  final int cacheEpoch;
  final int bookEpoch;
  final int hashEpoch;

  String get key => jsonEncode([bookId, canonicalHash]);

  bool get isEmpty => edits.isEmpty;

  Map<String, dynamic> toJson() => {
    'bookId': bookId,
    'canonicalHash': canonicalHash,
    'canonicalVersion': canonicalVersion,
    'activeRunId': activeRunId,
    'edits': edits.map((e) => e.toJson()).toList(),
    'status': status,
    'generation': generation,
    'updatedAt': updatedAt.millisecondsSinceEpoch,
    'sourceUtf16Length': sourceUtf16Length,
    'paragraphBoundaryFingerprint': paragraphBoundaryFingerprint,
    'integrityHash': integrityHash,
    if (model != null) 'model': model,
    if (promptHash != null) 'promptHash': promptHash,
    if (errorCodes.isNotEmpty) 'errorCodes': errorCodes,
    if (cacheEpoch != 0) 'cacheEpoch': cacheEpoch,
    if (bookEpoch != 0) 'bookEpoch': bookEpoch,
    if (hashEpoch != 0) 'hashEpoch': hashEpoch,
  };

  static AiFormalCacheEntry? fromJson(Object? raw) {
    final map = _mapOrNull(raw);
    if (map == null) return null;
    final bookId = map['bookId'];
    final hash = map['canonicalHash'];
    if (bookId is! String || hash is! String) return null;
    return AiFormalCacheEntry(
      bookId: bookId,
      canonicalHash: hash,
      canonicalVersion: _intOrNull(map['canonicalVersion']) ?? 1,
      activeRunId: map['activeRunId'] is String
          ? map['activeRunId'] as String
          : '',
      edits: [
        for (final entry in (map['edits'] as List? ?? const []))
          ?_rawEditFromJson(entry),
      ],
      status: map['status'] is String ? map['status'] as String : 'success',
      generation: _intOrNull(map['generation']) ?? 0,
      updatedAt: _date(map['updatedAt']) ?? DateTime.now(),
      sourceUtf16Length: _intOrNull(map['sourceUtf16Length']) ?? 0,
      paragraphBoundaryFingerprint:
          map['paragraphBoundaryFingerprint'] is String
          ? map['paragraphBoundaryFingerprint'] as String
          : '',
      integrityHash: map['integrityHash'] is String
          ? map['integrityHash'] as String
          : '',
      model: map['model'] is String ? map['model'] as String : null,
      promptHash: map['promptHash'] is String
          ? map['promptHash'] as String
          : null,
      errorCodes: _stringList(map['errorCodes']),
      cacheEpoch: _intOrNull(map['cacheEpoch']) ?? 0,
      bookEpoch: _intOrNull(map['bookEpoch']) ?? 0,
      hashEpoch: _intOrNull(map['hashEpoch']) ?? 0,
    );
  }
}

AiRawEdit? _rawEditFromJson(Object? raw) {
  final map = _mapOrNull(raw);
  if (map == null) return null;
  final original = map['original'];
  final replacement = map['replacement'];
  if (original is! String || replacement is! String) return null;
  return AiRawEdit(
    original: original,
    replacement: replacement,
    category: map['category'] is String ? map['category'] as String : '其他',
    reason: map['reason'] is String ? map['reason'] as String : '',
  );
}

@immutable
class AiRunRecord {
  const AiRunRecord({
    required this.runId,
    required this.kind,
    required this.bookId,
    required this.chapterId,
    required this.canonicalHash,
    required this.configSnapshotHash,
    required this.state,
    required this.attemptCount,
    required this.formalEligible,
    required this.startedAt,
    this.finishedAt,
    this.errorCodes = const [],
    this.detail,
  });

  final String runId;
  final AiRunKind kind;
  final String bookId;
  final String chapterId;
  final String canonicalHash;
  final String configSnapshotHash;
  final AiRunState state;
  final int attemptCount;
  final bool formalEligible;
  final DateTime startedAt;
  final DateTime? finishedAt;
  final List<String> errorCodes;
  final String? detail;

  AiRunRecord copyWith({
    AiRunState? state,
    int? attemptCount,
    DateTime? finishedAt,
    List<String>? errorCodes,
    String? detail,
  }) => AiRunRecord(
    runId: runId,
    kind: kind,
    bookId: bookId,
    chapterId: chapterId,
    canonicalHash: canonicalHash,
    configSnapshotHash: configSnapshotHash,
    state: state ?? this.state,
    attemptCount: attemptCount ?? this.attemptCount,
    formalEligible: formalEligible,
    startedAt: startedAt,
    finishedAt: finishedAt ?? this.finishedAt,
    errorCodes: errorCodes ?? this.errorCodes,
    detail: detail ?? this.detail,
  );

  Map<String, dynamic> toJson() => {
    'runId': runId,
    'kind': kind.wire,
    'bookId': bookId,
    'chapterId': chapterId,
    'canonicalHash': canonicalHash,
    'configSnapshotHash': configSnapshotHash,
    'state': state.name,
    'attemptCount': attemptCount,
    'formalEligible': formalEligible,
    'startedAt': startedAt.millisecondsSinceEpoch,
    if (finishedAt != null) 'finishedAt': finishedAt!.millisecondsSinceEpoch,
    if (errorCodes.isNotEmpty) 'errorCodes': errorCodes,
    if (detail != null) 'detail': detail,
  };

  static AiRunRecord? fromJson(Object? raw) {
    final map = _mapOrNull(raw);
    if (map == null) return null;
    final runId = map['runId'];
    final bookId = map['bookId'];
    if (runId is! String || bookId is! String) return null;
    return AiRunRecord(
      runId: runId,
      kind: AiRunKind.parse(map['kind']),
      bookId: bookId,
      chapterId: map['chapterId'] is String ? map['chapterId'] as String : '',
      canonicalHash: map['canonicalHash'] is String
          ? map['canonicalHash'] as String
          : '',
      configSnapshotHash: map['configSnapshotHash'] is String
          ? map['configSnapshotHash'] as String
          : '',
      state: AiRunState.parse(map['state']),
      attemptCount: _intOrNull(map['attemptCount']) ?? 0,
      formalEligible: map['formalEligible'] != false,
      startedAt: _date(map['startedAt']) ?? DateTime.now(),
      finishedAt: _date(map['finishedAt']),
      errorCodes: _stringList(map['errorCodes']),
      detail: map['detail'] is String ? map['detail'] as String : null,
    );
  }
}

@immutable
class AiUsage {
  const AiUsage({
    this.promptTokens,
    this.completionTokens,
    this.totalTokens,
    this.cachedTokens,
    this.reasoningTokens,
    this.status = AiUsageStatus.unknown,
  });

  final int? promptTokens;
  final int? completionTokens;
  final int? totalTokens;
  final int? cachedTokens;
  final int? reasoningTokens;
  final AiUsageStatus status;

  bool get hasAnyKnown =>
      promptTokens != null ||
      completionTokens != null ||
      totalTokens != null ||
      cachedTokens != null ||
      reasoningTokens != null;

  int get knownTokenSum {
    final total = totalTokens;
    if (total != null) return total;
    return (promptTokens ?? 0) + (completionTokens ?? 0);
  }

  Map<String, dynamic> toJson() => {
    if (promptTokens != null) 'promptTokens': promptTokens,
    if (completionTokens != null) 'completionTokens': completionTokens,
    if (totalTokens != null) 'totalTokens': totalTokens,
    if (cachedTokens != null) 'cachedTokens': cachedTokens,
    if (reasoningTokens != null) 'reasoningTokens': reasoningTokens,
    'status': status.name,
  };

  static AiUsage fromJson(Object? raw) {
    final map = _mapOrNull(raw) ?? const {};
    return AiUsage(
      promptTokens: _intOrNull(map['promptTokens']),
      completionTokens: _intOrNull(map['completionTokens']),
      totalTokens: _intOrNull(map['totalTokens']),
      cachedTokens: _intOrNull(map['cachedTokens']),
      reasoningTokens: _intOrNull(map['reasoningTokens']),
      status: AiUsageStatus.parse(map['status']),
    );
  }
}

@immutable
class AiRateSnapshot {
  const AiRateSnapshot({
    required this.currency,
    required this.inputPerMillionMicros,
    required this.outputPerMillionMicros,
    required this.cachePerMillionMicros,
    required this.reasoningPerMillionMicros,
    required this.effectiveAt,
    this.source = 'user',
  });

  final String currency;
  final int inputPerMillionMicros;
  final int outputPerMillionMicros;
  final int cachePerMillionMicros;
  final int reasoningPerMillionMicros;
  final DateTime effectiveAt;
  final String source;

  Map<String, dynamic> toJson() => {
    'currency': currency,
    'inputPerMillionMicros': inputPerMillionMicros,
    'outputPerMillionMicros': outputPerMillionMicros,
    'cachePerMillionMicros': cachePerMillionMicros,
    'reasoningPerMillionMicros': reasoningPerMillionMicros,
    'effectiveAt': effectiveAt.millisecondsSinceEpoch,
    'source': source,
  };

  static AiRateSnapshot? fromJson(Object? raw) {
    final map = _mapOrNull(raw);
    if (map == null) return null;
    final currency = map['currency'];
    if (currency is! String) return null;
    return AiRateSnapshot(
      currency: currency,
      inputPerMillionMicros: _intOrNull(map['inputPerMillionMicros']) ?? 0,
      outputPerMillionMicros: _intOrNull(map['outputPerMillionMicros']) ?? 0,
      cachePerMillionMicros: _intOrNull(map['cachePerMillionMicros']) ?? 0,
      reasoningPerMillionMicros:
          _intOrNull(map['reasoningPerMillionMicros']) ?? 0,
      effectiveAt: _date(map['effectiveAt']) ?? DateTime.now(),
      source: map['source'] is String ? map['source'] as String : 'user',
    );
  }
}

@immutable
class AiRateProfile {
  const AiRateProfile({
    required this.id,
    required this.label,
    required this.currency,
    required this.inputPerMillionMicros,
    required this.outputPerMillionMicros,
    required this.cachePerMillionMicros,
    required this.reasoningPerMillionMicros,
    required this.updatedAt,
    this.providerId,
    this.modelId,
  });

  final String id;
  final String label;
  final String currency;
  final int inputPerMillionMicros;
  final int outputPerMillionMicros;
  final int cachePerMillionMicros;
  final int reasoningPerMillionMicros;
  final DateTime updatedAt;
  final String? providerId;
  final String? modelId;

  bool matches(String provider, String model) {
    if (providerId != null && providerId != provider) return false;
    if (modelId != null && modelId != model) return false;
    return true;
  }

  AiRateSnapshot snapshot() => AiRateSnapshot(
    currency: currency,
    inputPerMillionMicros: inputPerMillionMicros,
    outputPerMillionMicros: outputPerMillionMicros,
    cachePerMillionMicros: cachePerMillionMicros,
    reasoningPerMillionMicros: reasoningPerMillionMicros,
    effectiveAt: updatedAt,
    source: 'user',
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    'currency': currency,
    'inputPerMillionMicros': inputPerMillionMicros,
    'outputPerMillionMicros': outputPerMillionMicros,
    'cachePerMillionMicros': cachePerMillionMicros,
    'reasoningPerMillionMicros': reasoningPerMillionMicros,
    'updatedAt': updatedAt.millisecondsSinceEpoch,
    if (providerId != null) 'providerId': providerId,
    if (modelId != null) 'modelId': modelId,
  };

  static AiRateProfile? fromJson(Object? raw) {
    final map = _mapOrNull(raw);
    if (map == null) return null;
    final id = map['id'];
    final label = map['label'];
    if (id is! String || label is! String) return null;
    return AiRateProfile(
      id: id,
      label: label,
      currency: map['currency'] is String ? map['currency'] as String : 'CNY',
      inputPerMillionMicros: _intOrNull(map['inputPerMillionMicros']) ?? 0,
      outputPerMillionMicros: _intOrNull(map['outputPerMillionMicros']) ?? 0,
      cachePerMillionMicros: _intOrNull(map['cachePerMillionMicros']) ?? 0,
      reasoningPerMillionMicros:
          _intOrNull(map['reasoningPerMillionMicros']) ?? 0,
      updatedAt: _date(map['updatedAt']) ?? DateTime.now(),
      providerId: map['providerId'] is String
          ? map['providerId'] as String
          : null,
      modelId: map['modelId'] is String ? map['modelId'] as String : null,
    );
  }
}

/// Converts token usage to integer micro-units of the billing currency.
/// Returns null when the provider did not report the token counts needed for a
/// deterministic estimate. Cache and reasoning tokens are priced separately
/// and are never charged twice.
int? aiEstimateCostMicros(AiUsage usage, AiRateSnapshot? rate) {
  if (rate == null) return null;
  final prompt = usage.promptTokens;
  final completion = usage.completionTokens;
  if (prompt == null || completion == null) return null;
  final cached = (usage.cachedTokens ?? 0).clamp(0, prompt);
  final reasoning = (usage.reasoningTokens ?? 0).clamp(0, completion);
  final inputTokens = prompt - cached;
  final outputTokens = completion - reasoning;
  final reasoningRate = rate.reasoningPerMillionMicros > 0
      ? rate.reasoningPerMillionMicros
      : rate.outputPerMillionMicros;
  final total =
      inputTokens * rate.inputPerMillionMicros +
      cached * rate.cachePerMillionMicros +
      outputTokens * rate.outputPerMillionMicros +
      reasoning * reasoningRate;
  return (total + 500000) ~/ 1000000;
}

@immutable
class AiRequestRecord {
  const AiRequestRecord({
    required this.requestId,
    required this.runId,
    required this.attemptNo,
    required this.providerId,
    required this.endpoint,
    required this.model,
    required this.mode,
    required this.usage,
    required this.startedAt,
    required this.latencyMs,
    this.rateSnapshot,
    this.costMicros,
    this.currency,
    this.errorCode,
    this.reason,
  });

  final String requestId;
  final String runId;
  final int attemptNo;
  final String providerId;
  final String endpoint;
  final String model;
  final AiOutputMode mode;
  final AiUsage usage;
  final DateTime startedAt;
  final int latencyMs;
  final AiRateSnapshot? rateSnapshot;
  final int? costMicros;
  final String? currency;
  final String? errorCode;
  final String? reason;

  Map<String, dynamic> toJson() => {
    'requestId': requestId,
    'runId': runId,
    'attemptNo': attemptNo,
    'providerId': providerId,
    'endpoint': endpoint,
    'model': model,
    'mode': mode.wire,
    'usage': usage.toJson(),
    'startedAt': startedAt.millisecondsSinceEpoch,
    'latencyMs': latencyMs,
    if (rateSnapshot != null) 'rateSnapshot': rateSnapshot!.toJson(),
    if (costMicros != null) 'costMicros': costMicros,
    if (currency != null) 'currency': currency,
    if (errorCode != null) 'errorCode': errorCode,
    if (reason != null) 'reason': reason,
  };

  static AiRequestRecord? fromJson(Object? raw) {
    final map = _mapOrNull(raw);
    if (map == null) return null;
    final id = map['requestId'];
    final runId = map['runId'];
    if (id is! String || runId is! String) return null;
    return AiRequestRecord(
      requestId: id,
      runId: runId,
      attemptNo: _intOrNull(map['attemptNo']) ?? 1,
      providerId: map['providerId'] is String
          ? map['providerId'] as String
          : '',
      endpoint: map['endpoint'] is String ? map['endpoint'] as String : '',
      model: map['model'] is String ? map['model'] as String : '',
      mode: AiOutputMode.parse(map['mode']),
      usage: AiUsage.fromJson(map['usage']),
      startedAt: _date(map['startedAt']) ?? DateTime.now(),
      latencyMs: _intOrNull(map['latencyMs']) ?? 0,
      rateSnapshot: AiRateSnapshot.fromJson(map['rateSnapshot']),
      costMicros: _intOrNull(map['costMicros']),
      currency: map['currency'] is String ? map['currency'] as String : null,
      errorCode: map['errorCode'] is String ? map['errorCode'] as String : null,
      reason: map['reason'] is String ? map['reason'] as String : null,
    );
  }
}

@immutable
class AiBudgetProjection {
  const AiBudgetProjection({
    required this.bucketDay,
    required this.bookId,
    required this.requestCount,
    required this.taskCount,
    required this.tokenSum,
    required this.unknownUsageCount,
    required this.costMicros,
    required this.currency,
    required this.updatedAt,
    this.costsByCurrency = const {},
    this.reservedRequestCount = 0,
    this.reservedTaskCount = 0,
    this.reservedRequestIds = const [],
    this.reservedTaskIds = const [],
    this.reservedRunIds = const {},
  });

  final String bucketDay;
  final String? bookId;

  /// Settled request/task counts. Reserved (in-flight) slots are tracked
  /// separately so restoring an older usage snapshot can never turn a real
  /// imported count back into "releasable" headroom.
  final int requestCount;
  final int taskCount;
  final int reservedRequestCount;
  final int reservedTaskCount;

  /// Request IDs behind the reserved counters. A record with a non-zero
  /// count and no ID is not a valid reservation in the current format.
  final List<String> reservedRequestIds;
  final List<String> reservedTaskIds;

  /// requestId -> the Run that was already persisted before the reservation.
  final Map<String, String> reservedRunIds;
  final int tokenSum;
  final int unknownUsageCount;
  final int costMicros;
  final String currency;
  final DateTime updatedAt;

  /// Costs are never summed across currencies. [costMicros]/[currency] mirror
  /// the display currency; the map keeps every provider currency separately.
  final Map<String, int> costsByCurrency;

  String get key => jsonEncode([bucketDay, bookId]);

  int get totalRequestCount => requestCount + reservedRequestCount;
  int get totalTaskCount => taskCount + reservedTaskCount;

  int costFor(String currency) =>
      costsByCurrency[currency] ??
      (costsByCurrency.isEmpty && this.currency == currency ? costMicros : 0);

  AiBudgetProjection copyWith({
    int? requestCount,
    int? taskCount,
    int? reservedRequestCount,
    int? reservedTaskCount,
    List<String>? reservedRequestIds,
    List<String>? reservedTaskIds,
    Map<String, String>? reservedRunIds,
    int? tokenSum,
    int? unknownUsageCount,
    int? costMicros,
    String? currency,
    DateTime? updatedAt,
    Map<String, int>? costsByCurrency,
  }) => AiBudgetProjection(
    bucketDay: bucketDay,
    bookId: bookId,
    requestCount: requestCount ?? this.requestCount,
    taskCount: taskCount ?? this.taskCount,
    reservedRequestCount: reservedRequestCount ?? this.reservedRequestCount,
    reservedTaskCount: reservedTaskCount ?? this.reservedTaskCount,
    reservedRequestIds: reservedRequestIds ?? this.reservedRequestIds,
    reservedTaskIds: reservedTaskIds ?? this.reservedTaskIds,
    reservedRunIds: reservedRunIds ?? this.reservedRunIds,
    tokenSum: tokenSum ?? this.tokenSum,
    unknownUsageCount: unknownUsageCount ?? this.unknownUsageCount,
    costMicros: costMicros ?? this.costMicros,
    currency: currency ?? this.currency,
    updatedAt: updatedAt ?? this.updatedAt,
    costsByCurrency: costsByCurrency ?? this.costsByCurrency,
  );

  Map<String, dynamic> toJson() => {
    'bucketDay': bucketDay,
    'bookId': bookId,
    'requestCount': requestCount,
    'taskCount': taskCount,
    'reservedRequestCount': reservedRequestCount,
    'reservedTaskCount': reservedTaskCount,
    if (reservedRequestIds.isNotEmpty) 'reservedRequestIds': reservedRequestIds,
    if (reservedTaskIds.isNotEmpty) 'reservedTaskIds': reservedTaskIds,
    if (reservedRunIds.isNotEmpty) 'reservedRunIds': reservedRunIds,
    'tokenSum': tokenSum,
    'unknownUsageCount': unknownUsageCount,
    'costMicros': costMicros,
    'currency': currency,
    'costs': costsByCurrency.isEmpty ? {currency: costMicros} : costsByCurrency,
    'updatedAt': updatedAt.millisecondsSinceEpoch,
  };

  static AiBudgetProjection? fromJson(Object? raw) {
    final map = _mapOrNull(raw);
    if (map == null) return null;
    final day = map['bucketDay'];
    if (day is! String) return null;
    final currency = map['currency'] is String
        ? map['currency'] as String
        : 'CNY';
    final costMicros = _intOrNull(map['costMicros']) ?? 0;
    final costs = <String, int>{};
    final rawCosts = map['costs'];
    if (rawCosts is Map) {
      for (final entry in rawCosts.entries) {
        final value = _intOrNull(entry.value);
        if (value != null) costs['${entry.key}'] = value;
      }
    }
    if (costs.isEmpty && costMicros > 0) costs[currency] = costMicros;
    return AiBudgetProjection(
      bucketDay: day,
      bookId: map['bookId'] is String ? map['bookId'] as String : null,
      requestCount: _intOrNull(map['requestCount']) ?? 0,
      taskCount: _intOrNull(map['taskCount']) ?? 0,
      reservedRequestCount: _intOrNull(map['reservedRequestCount']) ?? 0,
      reservedTaskCount: _intOrNull(map['reservedTaskCount']) ?? 0,
      reservedRequestIds: _stringList(map['reservedRequestIds']),
      reservedTaskIds: _stringList(map['reservedTaskIds']),
      reservedRunIds: _stringMap(map['reservedRunIds']),
      tokenSum: _intOrNull(map['tokenSum']) ?? 0,
      unknownUsageCount: _intOrNull(map['unknownUsageCount']) ?? 0,
      costMicros: costMicros,
      currency: currency,
      updatedAt: _date(map['updatedAt']) ?? DateTime.now(),
      costsByCurrency: Map.unmodifiable(costs),
    );
  }
}

@immutable
class AiPromptRecord {
  const AiPromptRecord({
    required this.promptId,
    required this.revision,
    required this.source,
    required this.text,
    required this.hash,
    required this.createdAt,
    this.bookId,
    this.parentId,
    this.active = true,
  });

  final String promptId;
  final String? bookId;
  final int revision;
  final String source;
  final String text;
  final String hash;
  final String? parentId;
  final DateTime createdAt;
  final bool active;

  AiPromptRecord copyWith({int? revision, bool? active, String? parentId}) =>
      AiPromptRecord(
        promptId: promptId,
        revision: revision ?? this.revision,
        source: source,
        text: text,
        hash: hash,
        createdAt: createdAt,
        bookId: bookId,
        parentId: parentId ?? this.parentId,
        active: active ?? this.active,
      );

  Map<String, dynamic> toJson() => {
    'promptId': promptId,
    if (bookId != null) 'bookId': bookId,
    'revision': revision,
    'source': source,
    'text': text,
    'hash': hash,
    if (parentId != null) 'parentId': parentId,
    'createdAt': createdAt.millisecondsSinceEpoch,
    'active': active,
  };

  static AiPromptRecord? fromJson(Object? raw) {
    final map = _mapOrNull(raw);
    if (map == null) return null;
    final id = map['promptId'];
    final text = map['text'];
    if (id is! String || text is! String) return null;
    return AiPromptRecord(
      promptId: id,
      bookId: map['bookId'] is String ? map['bookId'] as String : null,
      revision: _intOrNull(map['revision']) ?? 1,
      source: map['source'] is String ? map['source'] as String : 'manual',
      text: text,
      hash: map['hash'] is String ? map['hash'] as String : '',
      parentId: map['parentId'] is String ? map['parentId'] as String : null,
      createdAt: _date(map['createdAt']) ?? DateTime.now(),
      active: map['active'] != false,
    );
  }
}

@immutable
class AiPromptCandidate {
  const AiPromptCandidate({
    required this.candidateId,
    required this.bookId,
    required this.basePromptId,
    required this.body,
    required this.draftState,
    required this.feedbackCaseRevisions,
    required this.createdAt,
    this.adoptedAt,
  });

  final String candidateId;
  final String bookId;
  final String basePromptId;
  final String body;
  final String draftState;
  final Map<String, int> feedbackCaseRevisions;
  final DateTime createdAt;
  final DateTime? adoptedAt;

  Map<String, dynamic> toJson() => {
    'candidateId': candidateId,
    'bookId': bookId,
    'basePromptId': basePromptId,
    'body': body,
    'draftState': draftState,
    'feedbackCaseRevisions': feedbackCaseRevisions,
    'createdAt': createdAt.millisecondsSinceEpoch,
    if (adoptedAt != null) 'adoptedAt': adoptedAt!.millisecondsSinceEpoch,
  };

  static AiPromptCandidate? fromJson(Object? raw) {
    final map = _mapOrNull(raw);
    if (map == null) return null;
    final id = map['candidateId'];
    final bookId = map['bookId'];
    final body = map['body'];
    if (id is! String || bookId is! String || body is! String) return null;
    final revisions = <String, int>{};
    final rawRevisions = _mapOrNull(map['feedbackCaseRevisions']);
    rawRevisions?.forEach((key, value) {
      final v = _intOrNull(value);
      if (v != null) revisions[key] = v;
    });
    return AiPromptCandidate(
      candidateId: id,
      bookId: bookId,
      basePromptId: map['basePromptId'] is String
          ? map['basePromptId'] as String
          : '',
      body: body,
      draftState: map['draftState'] is String
          ? map['draftState'] as String
          : 'draft',
      feedbackCaseRevisions: revisions,
      createdAt: _date(map['createdAt']) ?? DateTime.now(),
      adoptedAt: _date(map['adoptedAt']),
    );
  }
}

@immutable
class AiTrialRecord {
  const AiTrialRecord({
    required this.trialId,
    required this.bookId,
    required this.candidateHash,
    required this.configSnapshotHash,
    required this.feedbackSnapshotHash,
    required this.feedbackCaseRevisions,
    required this.chapterHashes,
    required this.startedAt,
    required this.state,
  });

  final String trialId;
  final String bookId;
  final String candidateHash;
  final String configSnapshotHash;
  final String feedbackSnapshotHash;
  final Map<String, int> feedbackCaseRevisions;
  final List<String> chapterHashes;
  final DateTime startedAt;
  final String state;

  Map<String, dynamic> toJson() => {
    'trialId': trialId,
    'bookId': bookId,
    'candidateHash': candidateHash,
    'configSnapshotHash': configSnapshotHash,
    'feedbackSnapshotHash': feedbackSnapshotHash,
    'feedbackCaseRevisions': feedbackCaseRevisions,
    'chapterHashes': chapterHashes,
    'startedAt': startedAt.millisecondsSinceEpoch,
    'state': state,
  };

  static AiTrialRecord? fromJson(Object? raw) {
    final map = _mapOrNull(raw);
    if (map == null) return null;
    final id = map['trialId'];
    final bookId = map['bookId'];
    if (id is! String || bookId is! String) return null;
    final revisions = <String, int>{};
    final rawRevisions = _mapOrNull(map['feedbackCaseRevisions']);
    rawRevisions?.forEach((key, value) {
      final v = _intOrNull(value);
      if (v != null) revisions[key] = v;
    });
    return AiTrialRecord(
      trialId: id,
      bookId: bookId,
      candidateHash: map['candidateHash'] is String
          ? map['candidateHash'] as String
          : '',
      configSnapshotHash: map['configSnapshotHash'] is String
          ? map['configSnapshotHash'] as String
          : '',
      feedbackSnapshotHash: map['feedbackSnapshotHash'] is String
          ? map['feedbackSnapshotHash'] as String
          : '',
      feedbackCaseRevisions: revisions,
      chapterHashes: _stringList(map['chapterHashes']),
      startedAt: _date(map['startedAt']) ?? DateTime.now(),
      state: map['state'] is String ? map['state'] as String : 'running',
    );
  }
}

@immutable
class AiTrialFeedbackVerdict {
  const AiTrialFeedbackVerdict({
    required this.feedbackId,
    required this.revision,
    required this.verdict,
    required this.reasonCodes,
    this.manualDecision,
  });

  final String feedbackId;
  final int revision;
  final AiTrialVerdict verdict;
  final List<String> reasonCodes;
  final String? manualDecision;

  Map<String, dynamic> toJson() => {
    'feedbackId': feedbackId,
    'revision': revision,
    'verdict': verdict.name,
    'reasonCodes': reasonCodes,
    if (manualDecision != null) 'manualDecision': manualDecision,
  };

  static AiTrialFeedbackVerdict? fromJson(Object? raw) {
    final map = _mapOrNull(raw);
    if (map == null) return null;
    final id = map['feedbackId'];
    if (id is! String) return null;
    return AiTrialFeedbackVerdict(
      feedbackId: id,
      revision: _intOrNull(map['revision']) ?? 1,
      verdict: AiTrialVerdict.parse(map['verdict']),
      reasonCodes: _stringList(map['reasonCodes']),
      manualDecision: map['manualDecision'] is String
          ? map['manualDecision'] as String
          : null,
    );
  }
}

@immutable
class AiTrialResultRecord {
  const AiTrialResultRecord({
    required this.trialId,
    required this.chapterId,
    required this.canonicalHash,
    required this.runId,
    required this.rawValidatedEdits,
    required this.validationStatus,
    required this.perFeedback,
    required this.createdAt,
  });

  final String trialId;
  final String chapterId;
  final String canonicalHash;
  final String runId;
  final List<AiRawEdit>? rawValidatedEdits;
  final String validationStatus;
  final List<AiTrialFeedbackVerdict> perFeedback;
  final DateTime createdAt;

  Map<String, dynamic> toJson() => {
    'trialId': trialId,
    'chapterId': chapterId,
    'canonicalHash': canonicalHash,
    'runId': runId,
    if (rawValidatedEdits != null)
      'rawValidatedEdits': rawValidatedEdits!.map((e) => e.toJson()).toList(),
    'validationStatus': validationStatus,
    'perFeedback': perFeedback.map((e) => e.toJson()).toList(),
    'createdAt': createdAt.millisecondsSinceEpoch,
  };

  static AiTrialResultRecord? fromJson(Object? raw) {
    final map = _mapOrNull(raw);
    if (map == null) return null;
    final trialId = map['trialId'];
    if (trialId is! String) return null;
    final rawEdits = map['rawValidatedEdits'];
    return AiTrialResultRecord(
      trialId: trialId,
      chapterId: map['chapterId'] is String ? map['chapterId'] as String : '',
      canonicalHash: map['canonicalHash'] is String
          ? map['canonicalHash'] as String
          : '',
      runId: map['runId'] is String ? map['runId'] as String : '',
      rawValidatedEdits: rawEdits is List
          ? [for (final entry in rawEdits) ?_rawEditFromJson(entry)]
          : null,
      validationStatus: map['validationStatus'] is String
          ? map['validationStatus'] as String
          : 'unknown',
      perFeedback: [
        for (final entry in (map['perFeedback'] as List? ?? const []))
          ?AiTrialFeedbackVerdict.fromJson(entry),
      ],
      createdAt: _date(map['createdAt']) ?? DateTime.now(),
    );
  }
}

@immutable
class AiPendingBinding {
  const AiPendingBinding({
    required this.id,
    required this.sourceBookId,
    required this.sourceChapterId,
    required this.title,
    required this.canonicalHash,
    required this.canonicalVersion,
    required this.aggregate,
    required this.createdAt,
  });

  final String id;
  final String sourceBookId;
  final String sourceChapterId;
  final String title;
  final String canonicalHash;
  final int canonicalVersion;
  final AiFeedbackAggregate aggregate;
  final DateTime createdAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'sourceBookId': sourceBookId,
    'sourceChapterId': sourceChapterId,
    'title': title,
    'canonicalHash': canonicalHash,
    'canonicalVersion': canonicalVersion,
    'aggregate': aggregate.toJson(),
    'createdAt': createdAt.millisecondsSinceEpoch,
  };

  static AiPendingBinding? fromJson(Object? raw) {
    final map = _mapOrNull(raw);
    if (map == null) return null;
    final id = map['id'];
    final aggregate = AiFeedbackAggregate.fromJson(map['aggregate']);
    if (id is! String || aggregate == null) return null;
    return AiPendingBinding(
      id: id,
      sourceBookId: map['sourceBookId'] is String
          ? map['sourceBookId'] as String
          : '',
      sourceChapterId: map['sourceChapterId'] is String
          ? map['sourceChapterId'] as String
          : '',
      title: map['title'] is String ? map['title'] as String : '',
      canonicalHash: map['canonicalHash'] is String
          ? map['canonicalHash'] as String
          : '',
      canonicalVersion: _intOrNull(map['canonicalVersion']) ?? 1,
      aggregate: aggregate,
      createdAt: _date(map['createdAt']) ?? DateTime.now(),
    );
  }
}

/// Sentinel for copyWith methods that need to clear nullable fields.
const Object _unset = Object();

Map<String, dynamic>? _mapOrNull(Object? raw) {
  if (raw is Map<String, dynamic>) return raw;
  if (raw is Map) return raw.map((key, value) => MapEntry('$key', value));
  return null;
}

List<String> _stringList(Object? raw) => [
  if (raw is List)
    for (final value in raw)
      if (value is String) value,
];

Map<String, String> _stringMap(Object? raw) {
  final map = _mapOrNull(raw);
  if (map == null) return const {};
  return {
    for (final entry in map.entries)
      if (entry.value is String) entry.key.toString(): entry.value as String,
  };
}

int? _intOrNull(Object? value) => switch (value) {
  int v => v,
  num v when v.isFinite => v.toInt(),
  _ => null,
};

int _int(Object? value, int fallback, int min, int max) {
  final v = _intOrNull(value) ?? fallback;
  return v.clamp(min, max);
}

double? _doubleOrNull(Object? value) => switch (value) {
  num v when v.isFinite => v.toDouble(),
  _ => null,
};

double _double(Object? value, double fallback, double min, double max) {
  final v = _doubleOrNull(value) ?? fallback;
  return v.clamp(min, max);
}

DateTime? _date(Object? value) {
  final millis = _intOrNull(value);
  if (millis == null || millis <= 0) return null;
  return DateTime.fromMillisecondsSinceEpoch(millis);
}

/// Hive/JSON-safe encoding of bytes without a base64 prefix surprise.
String encodeBase64Bytes(Uint8List bytes) => base64Encode(bytes);
