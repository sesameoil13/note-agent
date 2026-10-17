import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/note_workspace.dart';

import 'audio_queue_test.dart' show wave;

void main() {
  test('macOS inspects real private WAV M4A and MP3 bytes without trusting extensions', () async {
    final root = await Directory.systemTemp.createTemp(
      'note-agent-native-inspect-',
    );
    addTearDown(() => root.delete(recursive: true));
    final canonical = Directory(await root.resolveSymbolicLinks());
    final probe = '${canonical.path}/inspect-audio';
    final compiled = await Process.run('/usr/bin/xcrun', [
      'swiftc',
      'macos/Runner/NativeAudio.swift',
      'tool/audio_inspection_probe.swift',
      '-o',
      probe,
    ]);
    expect(compiled.exitCode, 0, reason: compiled.stderr.toString());
    final local = Directory('${canonical.path}/local');
    final vault = await Directory('${canonical.path}/vault').create();
    final workspace = await NoteWorkspace.open(
      localDirectory: local,
      vaultDirectory: vault,
      audioInspector: _NativeInspector(probe, local.path),
    );
    addTearDown(workspace.close);
    final wav = await File('${canonical.path}/tone.wav')
        .writeAsBytes(wave(), flush: true);
    final m4a = File('${canonical.path}/tone.m4a');
    final converted = await Process.run('/usr/bin/afconvert', [
      wav.path,
      m4a.path,
      '-f',
      'm4af',
      '-d',
      'aac@16000',
      '-b',
      '32000',
    ]);
    expect(converted.exitCode, 0, reason: converted.stderr.toString());
    for (final fixture in [(wav, 'WAV', 'PCM'), (m4a, 'M4A', 'AAC')]) {
      final renamed = await fixture.$1.copy(
        '${canonical.path}/${fixture.$2}.data',
      );
      final result = await workspace.importAudio(
        original: renamed,
        submissionId: fixture.$2,
      );
      expect(
        result.metadata?.container,
        fixture.$2,
        reason: result.processingReason,
      );
      expect(result.metadata?.codec, fixture.$3);
      expect(result.metadata?.duration, const Duration(seconds: 1));
      expect(result.processingStatus, AudioProcessingStatus.pending);
    }
    // Optional separately acquired FFmpeg FATE fixture: never downloaded by tests.
    final mp3Path = Platform.environment['T11_MP3_FIXTURE'];
    if (mp3Path != null) {
      final disguised = await File(mp3Path).copy('${canonical.path}/mp3.data');
      final result = await workspace.importAudio(
        original: disguised,
        submissionId: 'MP3',
      );
      expect(
        result.metadata?.container,
        'MP3',
        reason: result.processingReason,
      );
      expect(result.metadata?.codec, 'MP3');
      expect(result.metadata?.duration.inMilliseconds, 10005);
    }
    final corrupt = await File('${canonical.path}/bad.m4a')
        .writeAsBytes((await m4a.readAsBytes()).sublist(0, 32));
    final failed = await workspace.importAudio(
      original: corrupt,
      submissionId: 'corrupt',
    );
    expect(failed.originalSaved, isTrue);
    expect(failed.processingStatus, AudioProcessingStatus.failed);
    expect(failed.metadata, isNull);
    // OS adapter scope is checked separately from business behavior.
    final outside = await Process.run(probe, [local.path, wav.path]);
    expect(outside.exitCode, isNot(0));
    final link = Link('${local.path}/audio-sources/escape');
    await link.create(canonical.path);
    final escaped = await Process.run(probe, [
      local.path,
      '${link.path}/tone.wav',
    ]);
    expect(escaped.exitCode, isNot(0));
  }, skip: !Platform.isMacOS);
}

class _NativeInspector implements AudioSourceInspector {
  _NativeInspector(this.probe, this.workspace);
  final String probe, workspace;
  @override
  Future<AudioSourceMetadata> inspectAudioSource(String privatePath) async {
    final result = await Process.run(probe, [workspace, privatePath]);
    if (result.exitCode != 0) {
      throw AudioInspectionFailure(result.stderr.toString());
    }
    return AudioSourceMetadata.fromJson(
      jsonDecode(result.stdout.toString()) as Map<String, dynamic>,
    );
  }
}
