import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/note_workspace.dart';

void main() {
  test('native start failure retains partial original and an honest playback attempt', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'phone-start-failure-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final workspace = await NoteWorkspace.open(
      localDirectory: Directory('${temporary.path}/local'),
      vaultDirectory: await Directory('${temporary.path}/vault').create(),
      audioPlatform: _InterruptedStart(),
      createId: () => 'partial-start',
    );
    addTearDown(workspace.close);
    await expectLater(
      workspace.startRecording(),
      throwsA(isA<AudioPlatformFailure>()),
    );
    final recording = workspace.recordings.single;
    expect(recording.status, RecordingStatus.interrupted);
    expect(recording.byteLength, 3);
    expect(recording.canPlay, isTrue);
    expect(await File(recording.originalPath).readAsBytes(), [7, 8, 9]);
    expect(await File(recording.sourcePath).exists(), isFalse);
    expect(workspace.audioSources, isEmpty);
    expect(workspace.recording.isActive, isFalse);
    await expectLater(
      workspace.playRecording(recording.id),
      throwsA(isA<AudioPlatformFailure>()),
    );
    expect(await File(recording.originalPath).readAsBytes(), [7, 8, 9]);
  });
}

class _InterruptedStart implements AudioPlatform {
  @override
  Future<void> startRecording(String originalPath) async {
    await File(originalPath).writeAsBytes([7, 8, 9], flush: true);
    throw const AudioPlatformFailure('系统无法开始录音，现有原件已保留。');
  }

  @override
  Future<void> play(String originalPath) async =>
      throw const AudioPlatformFailure('原件不完整，无法回放；原件仍保留。');
  @override
  Future<void> pauseRecording() async {}
  @override
  Future<void> resumeRecording() async {}
  @override
  Future<AudioCaptureSnapshot> recordingSnapshot() async =>
      throw UnimplementedError();
  @override
  Future<AudioCaptureSnapshot> stopRecording() async =>
      throw UnimplementedError();
  @override
  Future<Duration> inspectRecording(String originalPath) async =>
      throw UnimplementedError();
  @override
  Future<void> stopPlayback() async {}
  @override
  Future<AudioPlaybackSnapshot> playbackSnapshot() async =>
      throw UnimplementedError();
}
