import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'note_workspace.dart';

/// Recording controls use the same public workspace actions as behavioral tests.
class RecordingPanel extends StatefulWidget {
  const RecordingPanel({super.key, required this.workspace});
  final NoteWorkspace workspace;
  @override
  State<RecordingPanel> createState() => _RecordingPanelState();
}

class _RecordingPanelState extends State<RecordingPanel> {
  Timer? _timer;
  bool _busy = false;
  bool _polling = false;
  String? _error;

  @override
  void initState() {
    super.initState();
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
        !widget.workspace.playback.isPlaying) {
      return;
    }
    _polling = true;
    try {
      await widget.workspace.refreshRecording();
      await widget.workspace.refreshPlayback();
      if (mounted) setState(() {});
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
    if (mounted) setState(() => _busy = false);
  }

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
          const SizedBox(height: 32),
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
            const SizedBox(height: 16),
          ],
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
              IconButton(
                tooltip: playing ? '停止回放' : '回放原音频',
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
            RecordingStatus.exportFailed => '本机原音频已保留 · 笔记库未写入',
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
