/// Read-only shared-ledger view. Unknown charges are included in reserved funds,
/// never treated as refunded or as a prepaid balance.
class WorkspaceBudgetState {
  const WorkspaceBudgetState({
    this.monthLabel = '尚未连接',
    this.limitCnyMicros = 30000000,
    this.spentCnyMicros = 0,
    this.reservedCnyMicros = 0,
    this.unknownCnyMicros = 0,
    this.prepaidBalanceUsdMicros,
    this.connected = false,
    this.paused = true,
    this.message = '共享预算尚未连接；本机保存仍可使用。',
    this.quoteDescription,
  });
  final String monthLabel;
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
