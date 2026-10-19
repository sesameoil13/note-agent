import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/note_workspace.dart';

void main() {
  test('native finished original survives killed Dart process', () async {
    final root = Platform.environment['T09_RECOVERY_ROOT']!;
    final verify = Platform.environment['T09_RECOVERY_VERIFY'] == '1';
    final active = Platform.environment['T09_RECOVERY_PHASE'] == 'active';
    final audio = _NativeAudioBoundary(active: verify && active);
    final workspace = await NoteWorkspace.open(
      localDirectory: Directory('$root/local'),
      vaultDirectory: await Directory('$root/vault').create(recursive: true),
      audioPlatform: audio,
      createId: () => 'phone-background-recording',
    );
    if (!verify) {
      await workspace.startRecording();
      await File('$root/ready')
          .writeAsString('recording committed', flush: true);
      await Completer<void>().future;
      return;
    }
    if (active) {
      expect(workspace.recording.phase, RecordingPhase.paused);
      expect(workspace.recording.duration, const Duration(seconds: 15));
      expect(workspace.recordings.single.status, RecordingStatus.capturing);
      await workspace.resumeRecording();
      await workspace.stopRecording();
    }
    final restored = workspace.recordings.single;
    expect(restored.id, 'phone-background-recording');
    expect(restored.status, RecordingStatus.localSaved);
    expect(restored.duration, const Duration(seconds: 15));
    expect(await File(restored.originalPath).readAsBytes(), [1, 2, 3, 4]);
    expect(await File(restored.sourcePath).readAsBytes(), [1, 2, 3, 4]);
    expect(workspace.audioSources.single.id, restored.id);
    await workspace.playRecording(restored.id);
    expect(workspace.playback.isPlaying, isTrue);
    await File('$root/evidence.json').writeAsString(
      jsonEncode({
        'id': restored.id,
        'status': restored.status.name,
        'durationMs': restored.duration.inMilliseconds,
        'recordings': workspace.recordings.length,
        'originalBytes': restored.byteLength,
      }),
      flush: true,
    );
    await workspace.close();
  });
}

/// The OS recorder may finalize while the Flutter process is unavailable.
/// It owns the recording result; tests retain real SQLite and source files.
class _NativeAudioBoundary implements AudioPlatform, AudioRecordingRecovery {
  _NativeAudioBoundary({this.active = false});
  final bool active;
  bool resumed = false;
  @override
  Future<AudioCaptureSnapshot?> recoverRecording(String originalPath) async =>
      AudioCaptureSnapshot(
        phase: active ? AudioCapturePhase.paused : AudioCapturePhase.stopped,
        duration: Duration(seconds: 15),
      );
  @override
  Future<void> startRecording(String originalPath) async {
    await File(originalPath).writeAsBytes([1, 2, 3, 4], flush: true);
  }

  @override
  Future<AudioCaptureSnapshot> recordingSnapshot() async =>
      AudioCaptureSnapshot(
        phase: resumed ? AudioCapturePhase.recording : AudioCapturePhase.paused,
        duration: const Duration(seconds: 15),
      );
  @override
  Future<Duration> inspectRecording(String originalPath) async =>
      const Duration(seconds: 15);
  @override
  Future<void> play(String originalPath) async {}
  @override
  Future<void> pauseRecording() async {}
  @override
  Future<void> resumeRecording() async {
    resumed = true;
  }

  @override
  Future<void> stopPlayback() async {}
  @override
  Future<AudioPlaybackSnapshot> playbackSnapshot() async =>
      const AudioPlaybackSnapshot(isPlaying: false, position: Duration.zero);
  @override
  Future<AudioCaptureSnapshot> stopRecording() async {
    if (!active) {
      throw StateError(
        'Never stop a different native recording during recovery.',
      );
    }
    return const AudioCaptureSnapshot(
      phase: AudioCapturePhase.stopped,
      duration: Duration(seconds: 15),
    );
  }
}
