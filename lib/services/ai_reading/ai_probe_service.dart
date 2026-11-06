import 'ai_budget.dart';
import 'ai_client.dart';
import 'ai_models.dart';
import 'ai_settings.dart';
import 'ai_store.dart';

/// One budgeted, ledgered provider connectivity probe.
///
/// A probe does not contain chapter text, so it may run before the user turns
/// on AI reading and before cloud-content consent. It still uses the same
/// budget buckets and request ledger as normal calls: a test request that is
/// billed by the provider must be visible and must stop at the configured
/// limits.
class AiProbeService {
  AiProbeService({
    AiStore? store,
    AiSettingsStore? settings,
    AiBudgetService? budget,
    AiChatCompletionsClient? client,
  }) : _store = store ?? AiStore.instance,
       _settings = settings ?? AiSettingsStore.instance,
       _budget = budget ?? AiBudgetService.instance,
       _client = client ?? AiChatCompletionsClient();

  static final instance = AiProbeService();

  static const probeBookId = '__provider_probe__';

  final AiStore _store;
  final AiSettingsStore _settings;
  final AiBudgetService _budget;
  final AiChatCompletionsClient _client;

  Future<AiModelCapability> probe({
    required AiProviderProfile profile,
    required String apiKey,
    required String model,
    required AiOutputMode outputMode,
    required Duration timeout,
  }) async {
    await _settings.init();
    await _store.init();
    final reserved = await _budget.reserve(
      bookId: probeBookId,
      automatic: false,
      countTask: true,
      requireEnabled: false,
      requireConsent: false,
    );
    final reservation = reserved.reservation;
    if (reservation == null) {
      throw AiNetworkException(
        reserved.code ?? 'BUDGET_EXCEEDED',
        reserved.reason ?? '预算已用完',
      );
    }

    final started = DateTime.now();
    final runId = 'run_${started.microsecondsSinceEpoch.toRadixString(36)}';
    var usage = const AiUsage();
    String? errorCode;
    AiModelCapability? capability;
    Object? failure;
    try {
      capability = await _client.probe(
        profile: profile,
        apiKey: apiKey,
        model: model,
        outputMode: outputMode,
        timeout: timeout,
        onUsage: (reported, reportedError) {
          usage = reported;
          errorCode = reportedError;
        },
      );
    } catch (error) {
      failure = error;
      errorCode = error is AiNetworkException ? error.code : 'PROBE_FAILED';
    }

    final finished = DateTime.now();
    final rate = _settings.rateFor(profile.id, model)?.snapshot();
    final request = AiRequestRecord(
      requestId: 'req_${finished.microsecondsSinceEpoch.toRadixString(36)}',
      runId: runId,
      attemptNo: 1,
      providerId: profile.id,
      endpoint: AiChatCompletionsClient.endpoint(profile.baseUrl).toString(),
      model: model,
      mode: outputMode,
      usage: usage,
      startedAt: started,
      latencyMs: finished.difference(started).inMilliseconds,
      errorCode: errorCode,
      rateSnapshot: rate,
      costMicros: aiEstimateCostMicros(usage, rate),
      currency: rate?.currency ?? _settings.global.costCurrency,
      reason: 'provider_probe',
    );
    await _store.putRequest(request);
    await _budget.settle(reservation: reservation, request: request);
    await _store.putRun(
      AiRunRecord(
        runId: runId,
        kind: AiRunKind.probe,
        bookId: '',
        chapterId: '',
        canonicalHash: '',
        configSnapshotHash: '',
        state: capability?.ok == true ? AiRunState.success : AiRunState.failed,
        attemptCount: 1,
        formalEligible: false,
        startedAt: started,
        finishedAt: finished,
        errorCodes: [if (capability?.ok != true) errorCode ?? 'PROBE_FAILED'],
        detail: capability?.detail,
      ),
    );

    if (failure != null) throw failure;
    return capability!;
  }
}
