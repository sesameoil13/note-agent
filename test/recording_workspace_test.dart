import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/note_workspace.dart';

import 'audio_queue_test.dart' show wave;

void main() {
  test(
    'paused offline recording keeps its original and plays after restart',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'note-agent-t08-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final local = Directory('${temporary.path}/local');
      final vault = await Directory('${temporary.path}/vault').create();
      final microphone = _ControlledAudio();
      final workspace = await NoteWorkspace.open(
        localDirectory: local,
        vaultDirectory: vault,
        audioPlatform: microphone,
        createId: () => 'offline-audio',
      );

      await workspace.startRecording();
      microphone.advance(const Duration(seconds: 15), 0.65);
      await workspace.refreshRecording();
      expect(workspace.recording.phase, RecordingPhase.recording);
      expect(workspace.recording.duration, const Duration(seconds: 15));
      expect(workspace.recording.levels.last, 0.65);
      await workspace.pauseRecording();
      expect(workspace.recording.phase, RecordingPhase.paused);
      await workspace.resumeRecording();
      microphone.advance(const Duration(seconds: 20), 0.4);
      final saved = await workspace.stopRecording();
      expect(saved.id, 'offline-audio');
      expect(saved.duration, const Duration(seconds: 20));
      expect(saved.status, RecordingStatus.localSaved);
      expect(saved.byteLength, _ControlledAudio.original.length);
      expect(
        await File(saved.originalPath).readAsBytes(),
        _ControlledAudio.original,
      );
      expect(
        await File(saved.sourcePath).readAsBytes(),
        _ControlledAudio.original,
      );
      expect(workspace.notes, isEmpty);
      await workspace.close();

      final reopened = await NoteWorkspace.open(
        localDirectory: local,
        vaultDirectory: vault,
        audioPlatform: _ControlledAudio(),
      );
      addTearDown(reopened.close);
      final restored = reopened.recordings.single;
      expect(restored.id, saved.id);
      expect(restored.duration, const Duration(seconds: 20));
      await reopened.playRecording(restored.id);
      expect(reopened.playback.recordingId, saved.id);
      expect(reopened.playback.isPlaying, isTrue);
    },
  );
  test('five minute recording saves automatically without a visible recorder screen', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'note-agent-t08-limit-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final microphone = _ControlledAudio();
    final workspace = await NoteWorkspace.open(
      localDirectory: Directory('${temporary.path}/local'),
      vaultDirectory: await Directory('${temporary.path}/vault').create(),
      audioPlatform: microphone,
      createId: () => 'five-minute-audio',
    );
    addTearDown(workspace.close);
    await workspace.startRecording();
    microphone.advance(const Duration(minutes: 5), 0.5);
    for (var attempt = 0; attempt < 20; attempt++) {
      if (workspace.recordings.single.status == RecordingStatus.localSaved) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(workspace.recordings.single.status, RecordingStatus.localSaved);
    expect(workspace.recordings.single.duration, const Duration(minutes: 5));
    expect(workspace.recording.isActive, isFalse);
  });
  test('a recording slightly past five minutes is not refused like an imported file', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'note-agent-t08-encoded-limit-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final microphone = _LongWaveAudio();
    final workspace = await NoteWorkspace.open(
      localDirectory: Directory('${temporary.path}/local'),
      vaultDirectory: await Directory('${temporary.path}/vault').create(),
      audioPlatform: microphone,
      createId: () => 'encoded-past-limit',
    );
    addTearDown(workspace.close);
    await workspace.startRecording();
    microphone.advance(const Duration(minutes: 5), 0.5);
    await workspace.stopRecording();
    final source = workspace.audioSources.single;
    expect(source.metadata!.duration, const Duration(seconds: 301));
    expect(source.processingStatus, AudioProcessingStatus.pending);
  });
  test('interrupted saving retains original bytes and honest playback attempt after restart', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'note-agent-t08-interrupted-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final local = Directory('${temporary.path}/local');
    final vault = await Directory('${temporary.path}/vault').create();
    final microphone = _InterruptedAudio();
    final workspace = await NoteWorkspace.open(
      localDirectory: local,
      vaultDirectory: vault,
      audioPlatform: microphone,
      createId: () => 'interrupted-audio',
    );
    await workspace.startRecording();
    microphone.advance(const Duration(seconds: 15), 0.5);
    await expectLater(workspace.stopRecording(), throwsStateError);
    final interrupted = workspace.recordings.single;
    expect(interrupted.status, RecordingStatus.interrupted);
    expect(interrupted.byteLength, _ControlledAudio.original.length);
    expect(interrupted.canPlay, isTrue);
    expect(
      await File(interrupted.originalPath).readAsBytes(),
      _ControlledAudio.original,
    );
    expect(await File(interrupted.sourcePath).exists(), isFalse);
    await workspace.close();
    final reopened = await NoteWorkspace.open(
      localDirectory: local,
      vaultDirectory: vault,
      audioPlatform: _ControlledAudio(),
    );
    addTearDown(reopened.close);
    expect(reopened.recordings.single.status, RecordingStatus.interrupted);
    await reopened.playRecording(interrupted.id);
    expect(reopened.playback.isPlaying, isTrue);
  });
  test(
    'denied microphone never reports a saved recording and can retry',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'note-agent-t08-denied-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final microphone = _DeniedAudio();
      var identity = 0;
      final workspace = await NoteWorkspace.open(
        localDirectory: Directory('${temporary.path}/local'),
        vaultDirectory: await Directory('${temporary.path}/vault').create(),
        audioPlatform: microphone,
        createId: () => 'permission-${++identity}',
      );
      addTearDown(workspace.close);
      await expectLater(workspace.startRecording(), throwsStateError);
      expect(workspace.recording.phase, RecordingPhase.failed);
      expect(workspace.recording.isActive, isFalse);
      expect(workspace.recordings.single.status, RecordingStatus.failed);
      expect(workspace.recordings.single.canPlay, isFalse);
      expect(
        await File(workspace.recordings.single.originalPath).exists(),
        isFalse,
      );
      microphone.denied = false;
      await workspace.startRecording();
      microphone.advance(const Duration(seconds: 15), 0.5);
      final saved = await workspace.stopRecording();
      expect(saved.status, RecordingStatus.localSaved);
      expect(saved.id, 'permission-2');
    },
  );

  test('vault failure retains playable original and retry after restart uses same identity', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'note-agent-t08-vault-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final local = Directory('${temporary.path}/local');
    final vault = await Directory('${temporary.path}/vault').create();
    await File('${vault.path}/attachments').writeAsString('blocked directory');
    final microphone = _ControlledAudio();
    final workspace = await NoteWorkspace.open(
      localDirectory: local,
      vaultDirectory: vault,
      audioPlatform: microphone,
      createId: () => 'retained-original',
    );
    await workspace.startRecording();
    microphone.advance(const Duration(seconds: 15), 0.5);
    final saved = await workspace.stopRecording();
    expect(saved.status, RecordingStatus.exportFailed);
    expect(
      await File(saved.originalPath).readAsBytes(),
      _ControlledAudio.original,
    );
    await workspace.playRecording(saved.id);
    expect(workspace.playback.isPlaying, isTrue);
    await workspace.close();
    await File('${vault.path}/attachments').delete();
    final reopened = await NoteWorkspace.open(
      localDirectory: local,
      vaultDirectory: vault,
      audioPlatform: _ControlledAudio(),
    );
    addTearDown(reopened.close);
    final retried = await reopened.retryRecordingExport(saved.id);
    expect(retried.id, saved.id);
    expect(retried.status, RecordingStatus.localSaved);
    expect(reopened.recordings, hasLength(1));
    expect(
      await File(retried.sourcePath).readAsBytes(),
      _ControlledAudio.original,
    );
  });

  test('interrupted vault publication resumes with durable original and no duplicate recording', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'note-agent-t08-publication-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final local = Directory('${temporary.path}/local');
    final vault = await Directory('${temporary.path}/vault').create();
    final microphone = _ControlledAudio();
    final workspace = await NoteWorkspace.open(
      localDirectory: local,
      vaultStorage: _InterruptedBinaryVault(
        Directory(await vault.resolveSymbolicLinks()),
      ),
      audioPlatform: microphone,
      createId: () => 'pending-publication',
    );
    await workspace.startRecording();
    microphone.advance(const Duration(seconds: 15), 0.5);
    await expectLater(workspace.stopRecording(), throwsStateError);
    final pending = workspace.recordings.single;
    expect(pending.status, RecordingStatus.savePending);
    expect(await File(pending.sourcePath).exists(), isFalse);
    await workspace.close();
    final reopened = await NoteWorkspace.open(
      localDirectory: local,
      vaultDirectory: vault,
      audioPlatform: _ControlledAudio(),
    );
    addTearDown(reopened.close);
    final restored = reopened.recordings.single;
    expect(restored.id, pending.id);
    expect(restored.status, RecordingStatus.localSaved);
    expect(
      await File(restored.sourcePath).readAsBytes(),
      _ControlledAudio.original,
    );
    expect(
      await File(restored.originalPath).readAsBytes(),
      _ControlledAudio.original,
    );
  });

  test(
    'oversized original stays local and never claims a vault copy',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'note-agent-t08-oversize-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final microphone = _OversizedAudio();
      final workspace = await NoteWorkspace.open(
        localDirectory: Directory('${temporary.path}/local'),
        vaultDirectory: await Directory('${temporary.path}/vault').create(),
        audioPlatform: microphone,
        createId: () => 'oversized-original',
      );
      addTearDown(workspace.close);
      await workspace.startRecording();
      microphone.advance(const Duration(minutes: 10), 0.5);
      final saved = await workspace.stopRecording();
      expect(saved.byteLength, 5000001);
      expect(saved.status, RecordingStatus.exportFailed);
      expect(saved.error, contains('5MB'));
      expect(await File(saved.originalPath).length(), 5000001);
      expect(await File(saved.sourcePath).exists(), isFalse);
      await workspace.playRecording(saved.id);
      expect(workspace.playback.isPlaying, isTrue);
    },
  );
  test(
    'late microphone meter result cannot restart a saved recording state',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'note-agent-t08-race-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final microphone = _DelayedSnapshotAudio();
      final workspace = await NoteWorkspace.open(
        localDirectory: Directory('${temporary.path}/local'),
        vaultDirectory: await Directory('${temporary.path}/vault').create(),
        audioPlatform: microphone,
        createId: () => 'late-meter',
      );
      addTearDown(workspace.close);
      await workspace.startRecording();
      microphone.advance(const Duration(seconds: 15), 0.5);
      final refresh = workspace.refreshRecording();
      final saved = await workspace.stopRecording();
      microphone.gate.complete(
        const AudioCaptureSnapshot(
          phase: AudioCapturePhase.recording,
          duration: Duration(seconds: 15),
          level: 0.5,
        ),
      );
      await refresh;
      expect(saved.status, RecordingStatus.localSaved);
      expect(workspace.recording.isActive, isFalse);
      expect(workspace.recording.recordingId, isNull);
    },
  );
  test(
    'meter failure leaves explicit stop available to finish the original',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'note-agent-t08-meter-error-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final microphone = _FailedMeterAudio();
      final workspace = await NoteWorkspace.open(
        localDirectory: Directory('${temporary.path}/local'),
        vaultDirectory: await Directory('${temporary.path}/vault').create(),
        audioPlatform: microphone,
        createId: () => 'meter-error',
      );
      addTearDown(workspace.close);
      await workspace.startRecording();
      microphone.advance(const Duration(seconds: 15), 0.5);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(workspace.recording.isActive, isTrue);
      expect(workspace.recording.error, contains('meter unavailable'));
      final saved = await workspace.stopRecording();
      expect(saved.status, RecordingStatus.localSaved);
      expect(workspace.recording.isActive, isFalse);
    },
  );
}

/// Controlled microphone/player at the operating-system boundary. Files are real.
class _ControlledAudio implements AudioPlatform {
  static final original = Uint8List.fromList([
    0,
    0,
    0,
    24,
    102,
    116,
    121,
    112,
    77,
    52,
    65,
    32,
  ]);
  String? path;
  AudioCaptureSnapshot snapshot = const AudioCaptureSnapshot(
    phase: AudioCapturePhase.stopped,
    duration: Duration.zero,
  );

  void advance(Duration duration, double level) {
    snapshot = AudioCaptureSnapshot(
      phase: AudioCapturePhase.recording,
      duration: duration,
      level: level,
    );
  }

  @override
  Future<void> startRecording(String path) async {
    this.path = path;
    await File(path).writeAsBytes(original, flush: true);
    snapshot = const AudioCaptureSnapshot(
      phase: AudioCapturePhase.recording,
      duration: Duration.zero,
    );
  }

  @override
  Future<void> pauseRecording() async {
    snapshot = AudioCaptureSnapshot(
      phase: AudioCapturePhase.paused,
      duration: snapshot.duration,
    );
  }

  @override
  Future<void> resumeRecording() async {
    snapshot = AudioCaptureSnapshot(
      phase: AudioCapturePhase.recording,
      duration: snapshot.duration,
    );
  }

  @override
  Future<AudioCaptureSnapshot> recordingSnapshot() async => snapshot;
  @override
  Future<AudioCaptureSnapshot> stopRecording() async {
    snapshot = AudioCaptureSnapshot(
      phase: AudioCapturePhase.stopped,
      duration: snapshot.duration,
    );
    return snapshot;
  }

  @override
  Future<Duration> inspectRecording(String path) async => snapshot.duration;
  @override
  Future<void> play(String path) async {}
  @override
  Future<void> stopPlayback() async {}
  @override
  Future<AudioPlaybackSnapshot> playbackSnapshot() async =>
      const AudioPlaybackSnapshot(isPlaying: true, position: Duration.zero);
}

class _InterruptedAudio extends _ControlledAudio {
  @override
  Future<Duration> inspectRecording(String path) async =>
      throw StateError('Audio container interrupted');
}

class _DeniedAudio extends _ControlledAudio {
  bool denied = true;
  @override
  Future<void> startRecording(String path) async {
    if (denied) throw StateError('麦克风权限未开启，请在系统设置中允许。');
    await super.startRecording(path);
  }
}

class _InterruptedBinaryVault extends DirectoryVaultStorage {
  _InterruptedBinaryVault(super.directory);
  @override
  Future<void> publishFile(
    String relativePath,
    File original,
    String operationId,
  ) async {
    final staging = File(
      '${directory.path}/.note-agent-staging/$operationId/source.m4a',
    );
    await staging.parent.create(recursive: true);
    await staging.writeAsBytes([0, 0, 0], flush: true);
    throw StateError(
      'Simulated process interruption before source publication',
    );
  }
}

class _OversizedAudio extends _ControlledAudio {
  @override
  Future<void> startRecording(String path) async {
    await super.startRecording(path);
    final file = await File(path).open(mode: FileMode.append);
    try {
      await file.writeFrom(
        Uint8List(5000001 - _ControlledAudio.original.length),
      );
      await file.flush();
    } finally {
      await file.close();
    }
  }
}

/// Writes a WAV one second past the recorder limit, as an encoder's padding
/// might, so the saved original runs slightly longer than the recorder's cap.
class _LongWaveAudio extends _ControlledAudio {
  @override
  Future<void> startRecording(String path) async {
    await super.startRecording(path);
    await File(path).writeAsBytes(wave(seconds: 301), flush: true);
  }
}

class _DelayedSnapshotAudio extends _ControlledAudio {
  final gate = Completer<AudioCaptureSnapshot>();
  @override
  Future<AudioCaptureSnapshot> recordingSnapshot() => gate.future;
}

class _FailedMeterAudio extends _ControlledAudio {
  @override
  Future<AudioCaptureSnapshot> recordingSnapshot() async =>
      throw StateError('meter unavailable');
}
