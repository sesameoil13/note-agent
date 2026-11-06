import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/note_workspace.dart';

void main() {
  test('audio submission retains an inspected original and stable pending identity after reopen', () async {
    final root = await Directory.systemTemp.createTemp(
      'note-agent-audio-queue-',
    );
    addTearDown(() => root.delete(recursive: true));
    final local = Directory('${root.path}/local');
    final vault = await Directory('${root.path}/vault').create();
    // An actual PCM WAV deliberately has no audio filename extension.
    final source = await File('${root.path}/meeting.data')
        .writeAsBytes(wave(), flush: true);
    var sequence = 0;
    var workspace = await NoteWorkspace.open(
      localDirectory: local,
      vaultDirectory: vault,
      createId: () => 'audio-${sequence++}',
    );
    final results = await Future.wait([
      workspace.importAudio(original: source, submissionId: 'picker-1'),
      workspace.importAudio(original: source, submissionId: 'picker-1'),
    ]);
    expect(results[0].id, results[1].id);
    expect(workspace.audioSources, hasLength(1));
    final saved = workspace.audioSources.single;
    expect(saved.originalSaved, isTrue);
    expect(saved.metadata!.container, 'WAV');
    expect(saved.metadata!.codec, 'PCM');
    expect(saved.metadata!.duration, const Duration(seconds: 1));
    expect(saved.processingStatus, AudioProcessingStatus.pending);
    expect(await File(saved.originalPath).readAsBytes(), wave());
    expect(workspace.notes, isEmpty);
    await workspace.close();
    workspace = await NoteWorkspace.open(
      localDirectory: local,
      vaultDirectory: vault,
    );
    addTearDown(workspace.close);
    final replay = await workspace.importAudio(
      original: source,
      submissionId: 'picker-1',
    );
    expect(replay.id, saved.id);
    expect(replay.outputNoteId, saved.outputNoteId);
    final independent = await workspace.importAudio(
      original: source,
      submissionId: 'picker-2',
    );
    expect(independent.id, isNot(saved.id));
    expect(independent.digest, saved.digest);
    await source.writeAsBytes(wave(seconds: 2), flush: true);
    await expectLater(
      workspace.importAudio(original: source, submissionId: 'picker-1'),
      throwsArgumentError,
    );
    expect(workspace.audioSources, hasLength(2));
  });
  test('finalized native captures enter the same queue using their original identity', () async {
    final root = await Directory.systemTemp.createTemp(
      'note-agent-capture-queue-',
    );
    addTearDown(() => root.delete(recursive: true));
    final local = Directory('${root.path}/local');
    final vault = await Directory('${root.path}/vault').create();
    var workspace = await NoteWorkspace.open(
      localDirectory: local,
      vaultDirectory: vault,
      audioPlatform: _WaveMicrophone(),
      createId: () => 'capture-identity',
    );
    await workspace.startRecording();
    final recording = await workspace.stopRecording();
    expect(workspace.audioSources.single.id, recording.id);
    expect(workspace.audioSources.single.originalPath, recording.originalPath);
    expect(
      workspace.audioSources.single.processingStatus,
      AudioProcessingStatus.pending,
    );
    await workspace.close();
    workspace = await NoteWorkspace.open(
      localDirectory: local,
      vaultDirectory: vault,
      audioPlatform: _WaveMicrophone(),
    );
    addTearDown(workspace.close);
    expect(workspace.audioSources, hasLength(1));
    expect(workspace.audioSources.single.id, recording.id);
    expect(workspace.notes, isEmpty);
  });
  test('unsupported and incomplete inputs retain honest originals and reasons after reopen', () async {
    final root = await Directory.systemTemp.createTemp(
      'note-agent-audio-invalid-',
    );
    addTearDown(() => root.delete(recursive: true));
    final local = Directory('${root.path}/local');
    final vault = await Directory('${root.path}/vault').create();
    var workspace = await NoteWorkspace.open(
      localDirectory: local,
      vaultDirectory: vault,
    );
    final inputs = <String, List<int>>{
      'renamed.mp3': [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12],
      'empty.wav': [],
      'truncated.wav': wave().sublist(0, 100),
    };
    for (final entry in inputs.entries) {
      final file = await File('${root.path}/${entry.key}')
          .writeAsBytes(entry.value, flush: true);
      final saved = await workspace.importAudio(
        original: file,
        submissionId: entry.key,
      );
      expect(saved.originalSaved, isTrue);
      expect(saved.metadata, isNull);
      expect(saved.processingStatus, AudioProcessingStatus.failed);
      expect(saved.processingReason, isNotEmpty);
      expect(await File(saved.originalPath).readAsBytes(), entry.value);
    }
    final missing = await workspace.importAudio(
      original: File('${root.path}/missing.wav'),
      submissionId: 'missing',
    );
    expect(missing.originalSaved, isFalse);
    expect(missing.originalStatus, AudioOriginalStatus.incomplete);
    await workspace.close();
    workspace = await NoteWorkspace.open(
      localDirectory: local,
      vaultDirectory: vault,
    );
    addTearDown(workspace.close);
    expect(workspace.audioSources.where((s) => s.originalSaved), hasLength(3));
    final repairedFile = await File('${root.path}/missing.wav')
        .writeAsBytes(wave(), flush: true);
    final repaired = await workspace.importAudio(
      original: repairedFile,
      submissionId: 'missing',
    );
    expect(repaired.id, missing.id);
    expect(repaired.originalSaved, isTrue);
    expect(repaired.processingStatus, AudioProcessingStatus.pending);
    expect(workspace.notes, isEmpty);
  });

  test('imported audio longer than five minutes is refused before sending and the original is kept', () async {
    final root = await Directory.systemTemp.createTemp(
      'note-agent-audio-large-',
    );
    addTearDown(() => root.delete(recursive: true));
    final workspace = await NoteWorkspace.open(
      localDirectory: Directory('${root.path}/local'),
      vaultDirectory: await Directory('${root.path}/vault').create(),
    );
    addTearDown(workspace.close);
    final file = await File('${root.path}/long.wav')
        .writeAsBytes(wave(seconds: 660), flush: true);
    final saved = await workspace.importAudio(
      original: file,
      submissionId: 'long',
    );
    final refused = workspace.audioSources.single;
    expect(refused.processingStatus, AudioProcessingStatus.failed);
    expect(refused.processingReason, contains('5 分钟'));
    expect(refused.originalSaved, isTrue);
    expect(await File(saved.originalPath).length(), 10560044);
    expect(refused.publicationStatus, AudioPublicationStatus.exceedsFileLimit);
    expect(await File(refused.sourcePath).exists(), isFalse);
    // Checking again cannot undo the refusal.
    expect(refused.canRetryCheck, isFalse);
    await workspace.retryAudioCheck(refused.id);
    expect(
      workspace.audioSources.single.processingStatus,
      AudioProcessingStatus.failed,
    );
    expect(workspace.notes, isEmpty);
  });

  test('imported audio of exactly five minutes is accepted for processing', () async {
    final root = await Directory.systemTemp.createTemp(
      'note-agent-audio-five-',
    );
    addTearDown(() => root.delete(recursive: true));
    final workspace = await NoteWorkspace.open(
      localDirectory: Directory('${root.path}/local'),
      vaultDirectory: await Directory('${root.path}/vault').create(),
    );
    addTearDown(workspace.close);
    final file = await File('${root.path}/five.wav')
        .writeAsBytes(wave(seconds: 300), flush: true);
    final saved = await workspace.importAudio(
      original: file,
      submissionId: 'five',
    );
    expect(saved.metadata!.duration, const Duration(minutes: 5));
    expect(saved.processingStatus, AudioProcessingStatus.pending);
  });


}

List<int> wave({int seconds = 1}) {
  const rate = 8000;
  final data = ByteData(44 + rate * seconds * 2);
  void tag(int offset, String text) {
    for (var i = 0; i < text.length; i++) {
      data.setUint8(offset + i, text.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  data.setUint32(4, data.lengthInBytes - 8, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, rate, Endian.little);
  data.setUint32(28, rate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  data.setUint32(40, rate * seconds * 2, Endian.little);
  // Non-silent, valid signed 16-bit PCM; expected duration comes from the fixture.
  for (var i = 44; i < data.lengthInBytes; i += 2) {
    data.setInt16(i, (i ~/ 2) % 16 < 8 ? 2048 : -2048, Endian.little);
  }
  return data.buffer.asUint8List();
}

class _WaveMicrophone implements AudioPlatform {
  late String path;
  @override
  Future<void> startRecording(String originalPath) async {
    path = originalPath;
    await File(path).writeAsBytes(wave(), flush: true);
  }

  @override
  Future<Duration> inspectRecording(String originalPath) async =>
      const Duration(seconds: 1);
  @override
  Future<void> pauseRecording() async {}
  @override
  Future<void> resumeRecording() async {}
  @override
  Future<AudioCaptureSnapshot> recordingSnapshot() async =>
      const AudioCaptureSnapshot(
        phase: AudioCapturePhase.recording,
        duration: Duration(seconds: 1),
      );
  @override
  Future<AudioCaptureSnapshot> stopRecording() async =>
      const AudioCaptureSnapshot(
        phase: AudioCapturePhase.stopped,
        duration: Duration(seconds: 1),
      );
  @override
  Future<void> play(String originalPath) async {}
  @override
  Future<void> stopPlayback() async {}
  @override
  Future<AudioPlaybackSnapshot> playbackSnapshot() async =>
      const AudioPlaybackSnapshot(isPlaying: false, position: Duration.zero);
}
