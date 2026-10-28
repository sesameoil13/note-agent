/// Read-only shared-ledger view. Unknown charges are included in reserved funds,
/// never treated as refunded or as a prepaid balance.
class WorkspaceBudgetState {
  const WorkspaceBudgetState({
    this.monthLabel = '尚未连接',
    this.limitCnyMicros = 30000000,
    this.spentCnyMicros = 0,
    this.spentUsdNanos = 0,
    this.reservedCnyMicros = 0,
    this.unknownCnyMicros = 0,
    this.prepaidBalanceUsdMicros,
    this.connected = false,
    this.paused = true,
    this.message = '共享预算尚未连接；本机保存仍可使用。',
    this.quoteDescription,
  });
  final String monthLabel;
  final int spentUsdNanos;
  final int limitCnyMicros, spentCnyMicros, reservedCnyMicros, unknownCnyMicros;

  /// Ordinary inference keys cannot read account credits. Null means unknown,
  /// never zero. Do not request a management key merely to fill this display.
  final int? prepaidBalanceUsdMicros;
  final bool connected, paused;
  final String message;
  final String? quoteDescription;
  int get remainingCnyMicros =>
      limitCnyMicros - spentCnyMicros - reservedCnyMicros;
  bool get nearLimit => connected && remainingCnyMicros <= limitCnyMicros ~/ 10;
}

enum TextProcessingStatus {
  /// A capture queued for automatic 整理 on this device, not yet sent.
  waiting,
  cancelled,
  queued,
  prepared,
  sending,
  costPending,
  completed,
  failed,
  review,
}

/// A paid request whose response was lost (ADR 0003). Bailian cannot look its
/// cost up by id, so the hold stays until the user records the charge shown
/// in the Bailian console.
class UnconfirmedCharge {
  const UnconfirmedCharge(this.attemptId, this.label, this.heldCnyMicros);
  final String attemptId, label;
  final int heldCnyMicros;
}

class WorkspaceTextJob {
  const WorkspaceTextJob({
    required this.id,
    required this.noteId,
    required this.status,
    this.message = '',
    this.attemptCount = 0,
    this.estimatedCnyMicros = 0,
    this.quoteDescription = '尚未取得费率',
    this.canRetry = false,
    this.generationIds = const [],
    this.knownCostCnyMicros,
    this.inputTokens,
    this.outputTokens,
    this.reorganization = false,
  });

  /// A user-requested re-organization whose result is previewed first.
  final bool reorganization;
  final String id, noteId, message;
  final TextProcessingStatus status;
  final int attemptCount, estimatedCnyMicros;
  final String quoteDescription;
  final bool canRetry;
  final List<String> generationIds;

  /// Settled cost in micro-元 from the shared ledger.
  final int? knownCostCnyMicros;
  final int? inputTokens, outputTokens;
}
