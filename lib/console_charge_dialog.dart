import 'package:flutter/material.dart';

import 'note_workspace.dart';

/// Bailian cannot look up a lost response's cost (ADR 0003), so the user
/// reads the charge in the console (费用与成本 → 账单明细) and records it here,
/// one request at a time. Zero means the request was not billed.
Future<void> recordConsoleCharges(
  BuildContext context,
  NoteWorkspace workspace,
  String key, {
  required Future<void> Function(Future<void> Function()) run,
}) async {
  // Only the ledger calls run as busy; waiting for the user does not.
  var charges = const <UnconfirmedCharge>[];
  await run(() async => charges = await workspace.unconfirmedCharges(key));
  for (final charge in charges) {
    if (!context.mounted) return;
    final micros = await showDialog<int>(
      context: context,
      builder: (_) => _ChargeDialog(charge: charge),
    );
    if (micros == null) return;
    await run(
      () => workspace.recordConfirmedCharge(key, charge.attemptId, micros),
    );
  }
  if (charges.isEmpty && context.mounted) {
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('没有待核对的请求。')));
  }
}

String _yuan(int micros) => '¥${(micros / 1000000).toStringAsFixed(4)}';

/// Whole micro-元 from up to six decimals of 元, or null.
int? _parseYuan(String text) {
  final match = RegExp(r'^(\d{1,2})(?:\.(\d{1,6}))?$').firstMatch(text.trim());
  if (match == null) return null;
  return int.parse(match[1]!) * 1000000 +
      int.parse((match[2] ?? '').padRight(6, '0'));
}

class _ChargeDialog extends StatefulWidget {
  const _ChargeDialog({required this.charge});
  final UnconfirmedCharge charge;
  @override
  State<_ChargeDialog> createState() => _ChargeDialogState();
}

class _ChargeDialogState extends State<_ChargeDialog> {
  final _amount = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('按控制台账单记录费用'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.charge.label),
        Text('预留 ${_yuan(widget.charge.heldCnyMicros)}'),
        const SizedBox(height: 8),
        const Text(
          '在阿里云控制台“费用与成本 → 账单明细”找到这次请求的实际扣费；没有扣费填 0。超出预留的金额也如实记录，之后会暂停新的收费任务。',
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _amount,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: '实际扣费（元）', errorText: _error),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('暂不记录'),
      ),
      FilledButton(
        onPressed: () {
          final micros = _parseYuan(_amount.text);
          if (micros == null || micros > 30000000) {
            setState(() => _error = '请输入金额，如 0.0065（最多 30 元）');
            return;
          }
          Navigator.pop(context, micros);
        },
        child: const Text('记录'),
      ),
    ],
  );
}
