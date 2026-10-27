import 'package:flutter/material.dart';

import 'note_workspace.dart';
import 'action_confirmation_screen.dart';

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
  bool _limitEdited = false;
  final _limit = TextEditingController();
  NoteWorkspace get w => widget.workspace;
  String money(int micros) => '¥${(micros / 1000000).toStringAsFixed(4)}';
  @override
  void initState() {
    super.initState();
    _limit.text = w.budget.connected
        ? (w.budget.limitCnyMicros / 1000000).toStringAsFixed(2)
        : '';
    _run(_refresh);
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
    } catch (e) {
      _error = e is StateError
          ? e.message.toString()
          : '操作未能确认。原文保留；费用预留不会因出错而自动清除。';
    }
    if (mounted) {
      setState(() {
        _busy = false;
      });
    }
  }

  Future<void> _refresh() async {
    await w.refreshBudget();
    if (w.budget.connected && !_limitEdited) {
      _limit.text = (w.budget.limitCnyMicros / 1000000).toStringAsFixed(2);
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
          (n.document != null || n.attachments.isEmpty) &&
          (widget.noteId == null || n.id == widget.noteId),
    );
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI 与共享预算'),
        actions: [
          IconButton(
            onPressed: _busy ? null : () => _run(_refresh),
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
            budget.connected
                ? '月上限 ${money(budget.limitCnyMicros)}\n本月已结算费用 \$${(budget.spentUsdNanos / 1000000000).toStringAsFixed(6)}\n保守折算消耗 ${money(budget.spentCnyMicros)}\n未结算预留 ${money(budget.reservedCnyMicros)}（其中结果未知 ${money(budget.unknownCnyMicros)}）\n剩余额度 ${money(budget.remainingCnyMicros)}'
                : '共享月上限 尚未核对（政策最多 30 元）\n本月已结算费用 未知\n保守折算消耗 未知\n未结算预留 未知\n其中结果未知费用 未知\n剩余额度 未知',
          ),
          if (budget.nearLimit) const Text('接近月上限，新的收费任务可能暂停；本机收集继续。'),
          Text(budget.message),
          const Divider(height: 32),
          const Text(
            '阿里云账户余额：未知，App 无权查询，请在阿里云控制台核对。余额可跨月使用，与本月消耗分开计算。App 不自动充值、不升级套餐；控制台自动充值设置需你自行核对。',
          ),
          const Text(
            '人民币消耗按各次冻结汇率（含 10% 汇率余量）保守折算，预留再含 25% 余量。30 元上限仅用于 AI 消耗，不包含 Obsidian Sync 订阅。保留未知费用可能暂时减少可用额度；跨月不会自动释放。',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _limit,
            enabled: !_busy && budget.connected,
            onChanged: (_) {
              _limitEdited = true;
            },
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: '共享月上限（人民币，最多 30 元；仅原设备可修改）',
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              onPressed: _busy || !budget.connected
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
                      _limitEdited = false;
                      await _refresh();
                    }),
              child: const Text('确认修改月上限'),
            ),
          ),
          const Divider(height: 32),
          const Text(
            '文字整理使用固定 DeepSeek V4.1 Flash。为匹配关联，同时发送最多 12 条本库笔记的标题与各 400 字以内的正文片段。预估只读取公开费率并预留共享额度；确认发送后才调用模型。网络临时失败最多重试 3 次，每次单独预留。已发送的未知费用不会当作退款。',
          ),
          if (_busy) const LinearProgressIndicator(),
          if (_error != null) Text(_error!),
          if (widget.noteId == null) ...[
            const Divider(height: 32),
            const Text('录音转写与整理'),
            for (final source in w.audioSources) ...[
              const SizedBox(height: 16),
              Text(
                source.originalName,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              if (!w.audioJobs.any((j) => j.sourceId == source.id))
                OutlinedButton(
                  onPressed: _busy
                      ? null
                      : () => _run(() async {
                          await w.prepareAudioProcessing(source.id);
                        }),
                  child: const Text('预估转写及整理（不上传）'),
                ),
              for (final job in w.audioJobs.where(
                (j) => j.sourceId == source.id,
              )) ...[
                Text(switch (job.status) {
                  AudioJobStatus.preparing => '等待两阶段预留核对',
                  AudioJobStatus.prepared => '已预留，音频尚未上传',
                  AudioJobStatus.sending => '正在转写，可能产生费用',
                  AudioJobStatus.transcribed => '完整转写已保存',
                  AudioJobStatus.organizing => '正在整理转写',
                  AudioJobStatus.completed => '处理结束，原音与完整转写保留',
                  AudioJobStatus.paused => '已暂停，请核对原因和费用',
                  AudioJobStatus.cancelled => '未发送任务已取消',
                }),
                if (job.message.isNotEmpty) Text(job.message),
                Text('两阶段首次合计预留 ${money(job.estimatedCnyMicros)}'),
                Text(job.description),
                if (job.transcript != null)
                  ExpansionTile(
                    title: const Text('查看完整转写'),
                    children: [SelectableText(job.transcript!)],
                  ),
                if (job.generationId != null)
                  SelectableText('转写费用编号：${job.generationId}'),
                Text(
                  '转写费用：${job.knownCostUsdNanos == null ? '未知' : '\$${(job.knownCostUsdNanos! / 1000000000).toStringAsFixed(9)}'}',
                ),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    if (job.status == AudioJobStatus.prepared)
                      FilledButton(
                        onPressed: _busy
                            ? null
                            : () => _run(() async {
                                await w.confirmAudioProcessing(source.id);
                              }),
                        child: const Text('确认上传并转写整理（两阶段可能计费）'),
                      ),
                    if (job.canCancel &&
                        [
                          AudioJobStatus.prepared,
                          AudioJobStatus.preparing,
                          AudioJobStatus.paused,
                        ].contains(job.status))
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => _run(() async {
                                await w.cancelAudioProcessing(source.id);
                              }),
                        child: const Text('取消未上传任务'),
                      ),
                    if (job.status == AudioJobStatus.paused &&
                        job.transcript == null)
                      OutlinedButton(
                        onPressed: _busy
                            ? null
                            : () => _run(() async {
                                await w.prepareAudioRetry(source.id);
                              }),
                        child: const Text('另行预估上传重试（原尝试可能已计费）'),
                      ),
                    if (job.status == AudioJobStatus.paused &&
                        job.transcript != null)
                      OutlinedButton(
                        onPressed: _busy
                            ? null
                            : () => _run(() async {
                                await w.prepareAudioOrganization(source.id);
                              }),
                        child: const Text('仅重新预估整理（不重传音频）'),
                      ),
                    if (job.status == AudioJobStatus.cancelled)
                      OutlinedButton(
                        onPressed: _busy
                            ? null
                            : () => _run(() async {
                                await w.prepareAudioProcessing(source.id);
                              }),
                        child: const Text('重新预估转写及整理'),
                      ),
                    if ([
                      AudioJobStatus.paused,
                      AudioJobStatus.completed,
                    ].contains(job.status))
                      OutlinedButton(
                        onPressed: _busy
                            ? null
                            : () => _run(() async {
                                await w.reconcileAudioProcessing(source.id);
                              }),
                        child: const Text('核对转写和整理费用（不重传）'),
                      ),
                  ],
                ),
              ],
            ],
          ],
          for (final note in notes) ...[
            const SizedBox(height: 20),
            Text(note.title, style: Theme.of(context).textTheme.titleMedium),
            if (w.textProcessingReadiness(note.id).message.isNotEmpty)
              Text(w.textProcessingReadiness(note.id).message),
            if (!jobs.any((j) => j.noteId == note.id))
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton(
                  onPressed:
                      _busy || !w.textProcessingReadiness(note.id).canPrepare
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
              if (w.pendingActionNotes.any((n) => n.id == note.id))
                OutlinedButton(
                  onPressed: _busy
                      ? null
                      : () async {
                          await Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => ActionConfirmationScreen(
                                workspace: w,
                                noteId: note.id,
                              ),
                            ),
                          );
                          if (mounted) setState(() {});
                        },
                  child: const Text('核对行动（不调用模型）'),
                ),
              if (job.estimatedCnyMicros > 0)
                Text('首次尝试预留 ${money(job.estimatedCnyMicros)}；实际按费用回执结算。'),
              Text(job.quoteDescription),
              if (job.generationIds.isNotEmpty)
                SelectableText('费用编号：${job.generationIds.join('、')}'),
              if (job.generationIds.isNotEmpty)
                Text(
                  '费用回执金额：${job.knownCostUsdNanos == null ? '未知' : '\$${(job.knownCostUsdNanos! / 1000000000).toStringAsFixed(9)}'}；最后一次输入 ${job.inputTokens ?? '未知'} / 输出 ${job.outputTokens ?? '未知'} token。尚未取得的费用仍按预留计。',
                ),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  if (job.status == TextProcessingStatus.prepared &&
                      !job.reorganization)
                    FilledButton(
                      onPressed: _busy
                          ? null
                          : () => _run(() async {
                              await w.processTextNote(note.id);
                            }),
                      child: const Text('确认发送并整理（可能产生费用）'),
                    ),
                  if (!job.reorganization &&
                      [
                        TextProcessingStatus.failed,
                        TextProcessingStatus.queued,
                        TextProcessingStatus.cancelled,
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
