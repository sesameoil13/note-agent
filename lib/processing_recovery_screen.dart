import 'package:flutter/material.dart';

import 'note_workspace.dart';

String _money(int micros) => '¥${(micros / 1000000).toStringAsFixed(4)}';

String processingRecoveryLabel(WorkspaceProcessingFailure f) =>
    switch (f.recovery) {
      ProcessingRecovery.automaticRetryScheduled => '等待自动重试',
      ProcessingRecovery.retry =>
        f.source == ProcessingFailureSource.document
            ? '重新提取（不调用模型）'
            : f.source == ProcessingFailureSource.audio
            ? '另行预估重试（原尝试可能已计费）'
            : '手动重试（另行预留，可能计费）',
      ProcessingRecovery.confirmPrepared => '确认发送（可能计费）',
      ProcessingRecovery.reconcileCost => '核对费用（不重新调用模型）',
      ProcessingRecovery.reselectOriginal => '需重新选择原件',
    };

/// Failed audio, document and text processing, with the next safe step.
class ProcessingFailuresScreen extends StatefulWidget {
  const ProcessingFailuresScreen({super.key, required this.workspace});
  final NoteWorkspace workspace;
  @override
  State<ProcessingFailuresScreen> createState() =>
      _ProcessingFailuresScreenState();
}

class _ProcessingFailuresScreenState extends State<ProcessingFailuresScreen> {
  String? _busy, _error;

  Future<void> _recover(WorkspaceProcessingFailure failure) async {
    setState(() {
      _busy = failure.id;
      _error = null;
    });
    try {
      await widget.workspace.recoverProcessingFailure(failure.id);
    } catch (e) {
      _error = e is StateError
          ? e.message.toString()
          : '恢复未能确认。原件与已完成阶段保留；费用预留不会因出错而清除。';
    }
    if (mounted) setState(() => _busy = null);
  }

  @override
  Widget build(BuildContext context) {
    final failures = widget.workspace.processingFailures;
    return Scaffold(
      appBar: AppBar(title: const Text('处理失败')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Text(
            '可恢复错误最多自动重试三次；之后在此手动重试。凭据、余额与预算问题不会自动重试。已完成的阶段不会重做，原件始终保留。',
          ),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (failures.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Text('没有需要恢复的处理。'),
            ),
          for (final f in failures) ...[
            const SizedBox(height: 20),
            Text(f.title, style: Theme.of(context).textTheme.titleMedium),
            Text(switch (f.source) {
              ProcessingFailureSource.audio => '录音处理',
              ProcessingFailureSource.document => '文档提取',
              ProcessingFailureSource.text => '文字整理',
            }),
            if (f.message.isNotEmpty) Text(f.message),
            if (f.automaticRetriesUsed > 0)
              Text('已自动重试 ${f.automaticRetriesUsed} 次'),
            if (f.nextAutomaticRetryAt != null)
              Text('下次自动重试：${formatNoteTime(f.nextAutomaticRetryAt!)}'),
            if (f.needsAccountAction)
              const Text('请先在 App 或阿里云控制台处理 Key、余额或预算，再手动重试。'),
            if (f.recovery == ProcessingRecovery.confirmPrepared &&
                f.estimatedCnyMicros > 0)
              Text('已预留 ${_money(f.estimatedCnyMicros)}；实际按费用回执结算。'),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton(
                onPressed:
                    _busy != null ||
                        f.recovery ==
                            ProcessingRecovery.automaticRetryScheduled ||
                        f.recovery == ProcessingRecovery.reselectOriginal
                    ? null
                    : () => _recover(f),
                child: Text(processingRecoveryLabel(f)),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Correction of a recording's complete transcript: a local edit only. It
/// syncs through the vault and is never sent to AI (GLOSSARY 整理).
class TranscriptCorrectionScreen extends StatefulWidget {
  const TranscriptCorrectionScreen({
    super.key,
    required this.workspace,
    required this.noteId,
  });
  final NoteWorkspace workspace;
  final String noteId;
  @override
  State<TranscriptCorrectionScreen> createState() =>
      _TranscriptCorrectionScreenState();
}

class _TranscriptCorrectionScreenState
    extends State<TranscriptCorrectionScreen> {
  late final TextEditingController _transcript;
  bool _busy = false;
  String? _error, _notice;
  NoteWorkspace get w => widget.workspace;
  WorkspaceNote get note => w.notes.firstWhere((n) => n.id == widget.noteId);

  @override
  void initState() {
    super.initState();
    _transcript = TextEditingController(text: note.originalText);
  }

  @override
  void dispose() {
    _transcript.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      await w.correctTranscript(widget.noteId, _transcript.text);
      _notice = '转写更正已保存。';
    } on StateError catch (e) {
      _error = e.message;
    } on ArgumentError catch (e) {
      _error = '${e.message}';
    } catch (_) {
      _error = '更正未能确认，原音与笔记保留。';
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('更正转写')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(note.title, style: Theme.of(context).textTheme.titleLarge),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (_notice != null) Text(_notice!),
          const SizedBox(height: 16),
          const Text('更正完整转写只改转写文件，不改原音或整理正文，也不调用模型。更正会同步到其他设备。'),
          TextField(
            key: const ValueKey('transcript-correction'),
            controller: _transcript,
            enabled: !_busy,
            maxLines: 8,
            decoration: const InputDecoration(labelText: '完整转写'),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              onPressed: _busy ? null : _save,
              child: const Text('保存转写更正（不调用模型）'),
            ),
          ),
        ],
      ),
    );
  }
}
