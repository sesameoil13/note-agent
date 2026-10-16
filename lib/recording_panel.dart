import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'note_workspace.dart';
import 'accessible_icon_button.dart';
import 'workspace_platform.dart';

/// Recording controls use the same public workspace actions as behavioral tests.
class RecordingPanel extends StatefulWidget {
  const RecordingPanel({
    super.key,
    required this.workspace,
    this.onStateChanged,
  });
  final NoteWorkspace workspace;
  final VoidCallback? onStateChanged;
  @override
  State<RecordingPanel> createState() => _RecordingPanelState();
}

class _RecordingPanelState extends State<RecordingPanel> {
  final _platform = WorkspacePlatform();
  Timer? _timer;
  String? _pendingSubmissionId;
  String _observedAudio = '';
  bool _busy = false;
  bool _polling = false;
  String? _error;
  RecordingState? _observedRecording;
  PlaybackState? _observedPlayback;

  @override
  void initState() {
    super.initState();
    _observedAudio = _audioSignature;
    _observedRecording = widget.workspace.recording;
    _observedPlayback = widget.workspace.playback;
    _timer = Timer.periodic(const Duration(milliseconds: 150), (_) => _poll());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _poll() async {
    if (_polling || _busy) return;
    if (!widget.workspace.recording.isActive &&
        !widget.workspace.playback.isPlaying &&
        identical(_observedRecording, widget.workspace.recording) &&
        identical(_observedPlayback, widget.workspace.playback) &&
        _observedAudio == _audioSignature) {
      return;
    }
    _polling = true;
    try {
      await widget.workspace.refreshRecording();
      if (widget.workspace.playback.isPlaying) {
        await widget.workspace.refreshPlayback();
      }
      final changedActivity =
          _observedRecording?.isActive != widget.workspace.recording.isActive;
      _observedAudio = _audioSignature;
      _observedRecording = widget.workspace.recording;
      _observedPlayback = widget.workspace.playback;
      if (mounted) {
        setState(() {});
        if (changedActivity) widget.onStateChanged?.call();
      }
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      _polling = false;
    }
  }

  String _message(Object error) =>
      error is StateError ? error.message : error.toString();
  Future<void> _act(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      _error = _message(error);
    }
    if (mounted) {
      _observedAudio = _audioSignature;
      _observedRecording = widget.workspace.recording;
      _observedPlayback = widget.workspace.playback;
      setState(() => _busy = false);
      widget.onStateChanged?.call();
    }
  }

  String get _audioSignature => widget.workspace.audioSources
      .map(
        (s) =>
            '${s.id}:${s.processingStatus}:${s.stage}:${s.processingReason}:${s.publicationStatus}',
      )
      .join('|');

  Future<void> _importAudio({String? submissionId}) => _act(() async {
    File? selected;
    try {
      selected = await _platform.chooseSourceFile(audioOnly: true);
      if (selected == null) return;
      final token =
          submissionId ??
          _pendingSubmissionId ??
          widget.workspace.newAudioSubmissionId();
      _pendingSubmissionId = token;
      await widget.workspace.importAudio(
        original: selected,
        submissionId: token,
      );
      _pendingSubmissionId = null;
      await widget.workspace.resumePendingAudioProcessing();
    } finally {
      if (selected != null) await _platform.releaseSourceFile(selected);
    }
  });

  @override
  Widget build(BuildContext context) {
    final workspace = widget.workspace;
    final state = workspace.recording;
    final active = state.isActive;
    final paused = state.phase == RecordingPhase.paused;
    final working =
        _busy ||
        state.phase == RecordingPhase.starting ||
        state.phase == RecordingPhase.saving;
    final color = Theme.of(context).colorScheme.primary;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            '收集录音',
            style: TextStyle(fontSize: 32, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          const Text(
            '离线也可保存。保留原音频，尚未转写。',
            style: TextStyle(color: Color(0xFF767C82), height: 1.5),
          ),
          const SizedBox(height: 24),
          if (_platform.supportsSourceFiles)
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: _busy ? null : _importAudio,
                icon: const Icon(Icons.audio_file),
                label: const Text('导入已有录音'),
              ),
            ),
          const SizedBox(height: 24),
          if (workspace.recordingAvailable)
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: const Color(0xFF1C2024),
                border: Border(
                  left: BorderSide(
                    color: active ? color : const Color(0xFF767C82),
                    width: 8,
                  ),
                  top: const BorderSide(color: Color(0xFF767C82)),
                  right: const BorderSide(color: Color(0xFF767C82)),
                  bottom: const BorderSide(color: Color(0xFF767C82)),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          switch (state.phase) {
                            RecordingPhase.starting => '等待麦克风权限',
                            RecordingPhase.recording => '录音中',
                            RecordingPhase.paused => '已暂停',
                            RecordingPhase.saving => '正在保存原音频',
                            RecordingPhase.failed => '录音未完成',
                            RecordingPhase.idle => '准备录音',
                          },
                          style: const TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      Text(
                        formatRecordingDuration(state.duration),
                        style: const TextStyle(
                          fontSize: 32,
                          fontFamily: 'monospace',
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Semantics(
                    label: paused
                        ? '录音已暂停，计时停止'
                        : active
                        ? '麦克风实时音量波形'
                        : '尚未开始录音',
                    child: SizedBox(
                      height: 80,
                      child: CustomPaint(
                        painter: _Waveform(
                          state.levels,
                          active && !paused ? color : const Color(0xFF767C82),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Wrap(
                    spacing: 16,
                    runSpacing: 16,
                    children: [
                      if (!active)
                        FilledButton.icon(
                          onPressed: working
                              ? null
                              : () => _act(workspace.startRecording),
                          icon: const Icon(Icons.mic),
                          label: const Text('开始录音'),
                        ),
                      if (active) ...[
                        FilledButton.icon(
                          onPressed: working
                              ? null
                              : () => _act(() async {
                                  await workspace.stopRecording();
                                }),
                          icon: const Icon(Icons.stop),
                          label: const Text('结束并保存'),
                        ),
                        OutlinedButton.icon(
                          onPressed: working
                              ? null
                              : () => _act(
                                  paused
                                      ? workspace.resumeRecording
                                      : workspace.pauseRecording,
                                ),
                          icon: Icon(paused ? Icons.mic : Icons.pause),
                          label: Text(paused ? '继续录音' : '暂停'),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    '支持 15 秒至 10 分钟；达到 10 分钟自动结束保存。',
                    style: TextStyle(color: Color(0xFF767C82), fontSize: 12),
                  ),
                ],
              ),
            ),
          if (_error != null || state.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: SelectableText(_error ?? state.error!),
            ),
          const SizedBox(height: 32),
          const Text(
            '原始录音',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 16),
          if (workspace.recordings.isEmpty)
            const Text(
              '保存的原音频会出现在这里。',
              style: TextStyle(color: Color(0xFF767C82)),
            ),
          for (final recording in workspace.recordings) ...[
            _recording(recording),
            if (workspace.audioSources.any((s) => s.id == recording.id))
              _processing(
                workspace.audioSources.firstWhere((s) => s.id == recording.id),
              ),
            const SizedBox(height: 16),
          ],
          for (final source in workspace.audioSources.where(
            (s) => !workspace.recordings.any((r) => r.id == s.id),
          )) ...[_importedSource(source), const SizedBox(height: 16)],
        ],
      ),
    );
  }

  Widget _processing(WorkspaceAudioSource source) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        switch (source.processingStatus) {
          AudioProcessingStatus.pending => '待处理',
          AudioProcessingStatus.processing =>
            source.stage == 'transcribe'
                ? '处理中 · 转写'
                : source.stage == 'organize'
                ? '处理中 · 整理'
                : '处理中 · 写入笔记',
          AudioProcessingStatus.failed => '失败',
          AudioProcessingStatus.completed => '处理完成',
        },
        style: TextStyle(
          color: source.processingStatus == AudioProcessingStatus.failed
              ? const Color(0xFFFF4A18)
              : const Color(0xFF767C82),
        ),
      ),
      if (source.processingReason != null)
        SelectableText(
          source.processingReason!,
          style: const TextStyle(fontSize: 12),
        ),
      if (source.nextAttemptAt != null)
        Text(
          '稍后重试：${formatNoteTime(source.nextAttemptAt!)} · 自动重试 ${source.automaticRetries}/3',
          style: const TextStyle(fontSize: 12),
        ),
      if (source.processingStatus == AudioProcessingStatus.failed &&
          source.originalSaved)
        TextButton(
          onPressed: _busy
              ? null
              : () => _act(
                  () => widget.workspace.retryAudioProcessing(source.id),
                ),
          child: const Text('重试处理'),
        ),
    ],
  );

  Widget _importedSource(WorkspaceAudioSource source) {
    final metadata = source.metadata;
    final playing =
        widget.workspace.playback.recordingId == source.id &&
        widget.workspace.playback.isPlaying;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1C2024),
        border: Border.all(color: const Color(0xFF767C82)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            source.originalName,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Text(
            source.originalSaved ? '本机原音频已保存' : '原件尚未完整保存',
            style: const TextStyle(fontSize: 12),
          ),
          Text(
            '${(source.byteLength / 1000).toStringAsFixed(1)} KB${metadata == null ? '' : ' · ${metadata.codec} / ${metadata.container} · ${formatRecordingDuration(metadata.duration)}'}',
            style: const TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 8),
          _processing(source),
          Text(switch (source.publicationStatus) {
            AudioPublicationStatus.pending => '原件待写入笔记库',
            AudioPublicationStatus.published => '原件已写入本机笔记库 · 官方 Sync 状态待核对',
            AudioPublicationStatus.exceedsFileLimit => '原件超过 5 MB · 仅本机保留，未同步',
            AudioPublicationStatus.failed => '原件笔记库写入未确认',
          }, style: const TextStyle(fontSize: 12, color: Color(0xFF767C82))),
          if (source.publicationError != null)
            SelectableText(
              source.publicationError!,
              style: const TextStyle(fontSize: 12),
            ),
          Wrap(
            spacing: 8,
            children: [
              if (source.originalSaved)
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => _act(
                          () =>
                              _platform.revealLocalSource(source.originalPath),
                        ),
                  child: const Text('打开原件'),
                ),
              if (source.originalSaved &&
                  metadata != null &&
                  widget.workspace.audioSourcePlaybackAvailable)
                TextButton(
                  onPressed: _busy || widget.workspace.recording.isActive
                      ? null
                      : () => _act(
                          playing
                              ? widget.workspace.stopPlayback
                              : () =>
                                    widget.workspace.playAudioSource(source.id),
                        ),
                  child: Text(playing ? '停止回放' : '回放原音频'),
                ),
              if (!source.originalSaved)
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => _importAudio(submissionId: source.submissionId),
                  child: const Text('重新选择原件'),
                ),
              if (source.publicationStatus == AudioPublicationStatus.failed)
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => _act(
                          () => widget.workspace.retryAudioSourceExport(
                            source.id,
                          ),
                        ),
                  child: const Text('重试写入笔记库'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _recording(WorkspaceRecording recording) {
    final playback = widget.workspace.playback;
    final playing = playback.recordingId == recording.id && playback.isPlaying;
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1C2024),
        border: Border.all(
          color: playing
              ? Theme.of(context).colorScheme.primary
              : const Color(0xFF767C82),
        ),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              AccessibleIconButton(
                label: playing ? '停止回放' : '回放原音频',
                onPressed:
                    _busy ||
                        widget.workspace.recording.isActive ||
                        !recording.canPlay
                    ? null
                    : () => _act(
                        playing
                            ? widget.workspace.stopPlayback
                            : () =>
                                  widget.workspace.playRecording(recording.id),
                      ),
                icon: Icon(playing ? Icons.stop : Icons.play_arrow),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '录音 · ${formatNoteTime(recording.createdAt)}',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              Text(
                formatRecordingDuration(
                  playing ? playback.position : recording.duration,
                ),
                style: const TextStyle(fontFamily: 'monospace'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(switch (recording.status) {
            RecordingStatus.capturing => '录制中 · 原音频尚未完成',
            RecordingStatus.savePending => '原音频已保留 · 待写入笔记库',
            RecordingStatus.localSaved => '本机原音频已保存 · 尚未转写',
            RecordingStatus.exportFailed => '本机原音频已保留 · 笔记库写入未确认',
            RecordingStatus.interrupted => '录音意外中断 · 请回放核对',
            RecordingStatus.failed => '未能开始录音',
          }, style: const TextStyle(color: Color(0xFF767C82), fontSize: 12)),
          if (recording.byteLength > 0)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '${(recording.byteLength / 1000).toStringAsFixed(1)} KB · AAC / M4A',
                style: const TextStyle(color: Color(0xFF767C82), fontSize: 12),
              ),
            ),
          if (recording.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SelectableText(
                recording.error!,
                style: const TextStyle(fontSize: 13),
              ),
            ),
          if (recording.status == RecordingStatus.exportFailed)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: _busy
                    ? null
                    : () => _act(() async {
                        await widget.workspace.retryRecordingExport(
                          recording.id,
                        );
                      }),
                child: const Text('重试写入笔记库'),
              ),
            ),
        ],
      ),
    );
  }
}

String formatRecordingDuration(Duration duration) =>
    '${duration.inMinutes.toString().padLeft(2, '0')}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}';

class _Waveform extends CustomPainter {
  _Waveform(this.levels, this.color);
  final List<double> levels;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    const count = 64;
    final width = size.width / count;
    for (var i = 0; i < count; i++) {
      final index = i - (count - levels.length);
      final value = index >= 0 ? levels[index] : 0.0;
      final height = 2 + math.sqrt(value.clamp(0, 1)) * (size.height - 2);
      canvas.drawRect(
        Rect.fromLTWH(
          i * width,
          (size.height - height) / 2,
          math.max(1, width - 4),
          height,
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_Waveform oldDelegate) =>
      oldDelegate.levels != levels || oldDelegate.color != color;
}
