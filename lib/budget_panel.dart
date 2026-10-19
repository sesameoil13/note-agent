import 'package:flutter/material.dart';

import 'note_workspace.dart';

/// All paid actions are explicit. Refreshing this page only reads the ledger.
class BudgetPanel extends StatefulWidget {
  const BudgetPanel({super.key, required this.workspace, this.noteId});
  final NoteWorkspace workspace;
  final String? noteId;
  @override
  State<BudgetPanel> createState() => _BudgetPanelState();
}

class _BudgetPanelState extends State<BudgetPanel> {
  bool _busy = false;
  String? _error;
  final _limit = TextEditingController();
  NoteWorkspace get w => widget.workspace;
  String money(int micros) => '¥${(micros / 1000000).toStringAsFixed(4)}';
  @override
  void initState() {
    super.initState();
    _limit.text = (w.budget.limitCnyMicros / 1000000).toStringAsFixed(2);
    _run(w.refreshBudget);
  }

  @override
  void dispose() {
    _limit.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (_) {
      _error = '操作未能确认。原文保留；费用预留不会因出错而自动清除。';
    }
    if (mounted) {
      setState(() {
        _busy = false;
      });
    }
  }

  String status(TextProcessingStatus value) => switch (value) {
    TextProcessingStatus.queued => '等待预算确认',
    TextProcessingStatus.prepared => '已预留，尚未发送',
    TextProcessingStatus.sending => '正在处理，请勿重复发送',
    TextProcessingStatus.costPending => '费用待核对',
    TextProcessingStatus.completed => '已整理并结算',
    TextProcessingStatus.failed => '暂停，原文已保存',
    TextProcessingStatus.review => '待确认，原文保留',
    TextProcessingStatus.cancelled => '未发送，已取消',
  };
  @override
  Widget build(BuildContext context) {
    final budget = w.budget;
    final jobs = w.textJobs;
    final notes = w.notes.where(
      (n) =>
          n.status == NoteStatus.localSaved &&
          n.document == null &&
          n.attachments.isEmpty &&
          (widget.noteId == null || n.id == widget.noteId),
    );
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI 与共享预算'),
        actions: [
          IconButton(
            onPressed: _busy ? null : () => _run(w.refreshBudget),
            tooltip: '刷新账本（不调用模型）',
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            '${budget.monthLabel} · 三端共享',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          Text(
            '月上限 ${money(budget.limitCnyMicros)}\n本月实际费用 \$${(budget.spentUsdNanos / 1000000000).toStringAsFixed(6)}\n保守折算消耗 ${money(budget.spentCnyMicros)}\n未结算预留 ${money(budget.reservedCnyMicros)}（其中结果未知 ${money(budget.unknownCnyMicros)}）\n剩余额度 ${money(budget.remainingCnyMicros)}',
          ),
          if (budget.nearLimit) const Text('接近月上限，新的收费任务可能暂停；本机收集继续。'),
          Text(budget.message),
          const Divider(height: 32),
          const Text(
            'OpenRouter 预付余额：未知。普通 Key 无权查询账户余额，请在 OpenRouter 官网核对。预付款可跨月使用，与本月消耗分开计算。App 不自动充值、不升级套餐；官网自动充值设置需你自行核对。',
          ),
          const Text(
            '人民币消耗按各次冻结汇率（含 10% 汇率余量）保守折算，预留再含 25% 余量。30 元上限仅用于 AI 消耗，不包含 Obsidian Sync 订阅。保留未知费用可能暂时减少可用额度；跨月不会自动释放。',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _limit,
            enabled: !_busy,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: '共享月上限（人民币，最多 30 元；仅原设备可修改）',
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              onPressed: _busy
                  ? null
                  : () => _run(() async {
                      final value = double.tryParse(_limit.text);
                      if (value == null ||
                          !value.isFinite ||
                          value <= 0 ||
                          value > 30) {
                        setState(() {
                          _error = '请输入大于 0 且不超过 30 元的金额。';
                        });
                        return;
                      }
                      await w.setMonthlyBudgetLimit((value * 1000000).round());
                    }),
              child: const Text('确认修改月上限'),
            ),
          ),
          const Divider(height: 32),
          const Text(
            '文字整理使用固定 DeepSeek V4.1 Flash。预估只读取公开费率并预留共享额度；确认发送后才调用模型。网络临时失败最多重试 3 次，每次单独预留。已发送的未知费用不会当作退款。',
          ),
          if (_busy) const LinearProgressIndicator(),
          if (_error != null) Text(_error!),
          for (final note in notes) ...[
            const SizedBox(height: 20),
            Text(note.title, style: Theme.of(context).textTheme.titleMedium),
            if (!jobs.any((j) => j.noteId == note.id))
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton(
                  onPressed: _busy
                      ? null
                      : () => _run(() async {
                          await w.prepareTextProcessing(note.id);
                        }),
                  child: const Text('预估并预留（不调用模型）'),
                ),
              ),
            for (final job in jobs.where((j) => j.noteId == note.id)) ...[
              Text('${status(job.status)} · 已准备 ${job.attemptCount} 次尝试'),
              if (job.message.isNotEmpty) Text(job.message),
              if (job.estimatedCnyMicros > 0)
                Text('首次尝试预留 ${money(job.estimatedCnyMicros)}；实际按费用回执结算。'),
              Text(job.quoteDescription),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  if (job.status == TextProcessingStatus.prepared)
                    FilledButton(
                      onPressed: _busy
                          ? null
                          : () => _run(() async {
                              await w.processTextNote(note.id);
                            }),
                      child: const Text('确认发送并整理（可能产生费用）'),
                    ),
                  if ([
                    TextProcessingStatus.failed,
                    TextProcessingStatus.queued,
                  ].contains(job.status))
                    OutlinedButton(
                      onPressed: _busy
                          ? null
                          : () => _run(() async {
                              await w.prepareTextProcessing(note.id);
                            }),
                      child: const Text('重新核对预留（不调用模型）'),
                    ),
                  if (job.status == TextProcessingStatus.prepared)
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => _run(() async {
                              await w.cancelTextProcessing(job.id);
                            }),
                      child: const Text('取消未发送任务'),
                    ),
                  if (job.canRetry)
                    OutlinedButton(
                      onPressed: _busy
                          ? null
                          : () => _run(() async {
                              await w.retryTextProcessing(job.id);
                            }),
                      child: const Text('另行预留并手动重试（可能计费）'),
                    ),
                  if ([
                    TextProcessingStatus.costPending,
                    TextProcessingStatus.review,
                    TextProcessingStatus.completed,
                  ].contains(job.status))
                    OutlinedButton(
                      onPressed: _busy
                          ? null
                          : () => _run(() async {
                              await w.reconcileTextProcessing(job.id);
                            }),
                      child: const Text('核对费用（不重新调用模型）'),
                    ),
                ],
              ),
            ],
          ],
        ],
      ),
    );
  }
}
