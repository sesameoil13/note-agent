import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/note_workspace.dart';

void main() {
  test('audio crash recovery worker', () async {
    final root = Platform.environment['T11_CRASH_ROOT']!;
    final phase = Platform.environment['T11_CRASH_PHASE']!;
    final verify = Platform.environment['T11_CRASH_VERIFY'] == '1';
    final local = Directory('$root/local');
    final vault = await Directory('$root/vault').create(recursive: true);
    final workspace = await NoteWorkspace.open(
      localDirectory: local,
      vaultDirectory: vault,
      audioInspector: !verify && phase == 'rename'
          ? _BarrierInspector(root)
          : PcmWaveInspector(),
      audioProcessor: _CrashProcessor(root, !verify ? phase : 'verify'),
      filePublisher: !verify && phase == 'publish'
          ? _BarrierPublisher(root)
          : null,
      createId: () => 'crash-source',
    );
    if (verify) {
      await workspace.resumePendingAudioProcessing();
      final replay = await workspace.importAudio(
        original: File('$root/original.wav'),
        submissionId: 'crash-token',
      );
      expect(replay.id, 'crash-source');
      expect(workspace.audioSources, hasLength(1));
      expect(workspace.audioSources.single.originalSaved, isTrue);
      expect(
        workspace.audioSources.single.processingStatus,
        AudioProcessingStatus.completed,
      );
      expect(workspace.notes.single.id, 'crash-source-note');
      expect(workspace.notes.single.originalText, '崩溃恢复的完整转写');
      expect(
        (await vault.list().where((f) => f.path.endsWith('.md')).toList()),
        hasLength(1),
      );
      await File('$root/evidence.json').writeAsString(
        jsonEncode({
          'phase': phase,
          'sourceId': replay.id,
          'noteId': workspace.notes.single.id,
          'notes': workspace.notes.length,
          'originalSaved': replay.originalSaved,
          'processingStatus':
              workspace.audioSources.single.processingStatus.name,
          'attempts': workspace.audioSources.single.attempts,
        }),
        flush: true,
      );
      await workspace.close();
    } else {
      await workspace.importAudio(
        original: File('$root/original.wav'),
        submissionId: 'crash-token',
      );
      await workspace.resumePendingAudioProcessing();
      fail('Crash barrier was not reached');
    }
  });
}

Future<Never> _barrier(String root) async {
  await File('$root/ready').writeAsString('committed boundary', flush: true);
  return Completer<Never>().future;
}

class _BarrierInspector implements AudioSourceInspector {
  _BarrierInspector(this.root);
  final String root;
  @override
  Future<AudioSourceMetadata> inspectAudioSource(String privatePath) =>
      _barrier(root);
}

class _CrashProcessor implements AudioProcessor {
  _CrashProcessor(this.root, this.phase);
  final String root, phase;
  @override
  bool get canReplayInterruptedRequests => true;
  @override
  Future<AudioTranscript> transcribe(AudioProcessingRequest request) async {
    if (phase == 'transcribe') await _barrier(root);
    return const AudioTranscript('崩溃恢复的完整转写');
  }

  @override
  Future<AudioOrganizedNote> organize(
    AudioProcessingRequest request,
    AudioTranscript transcript,
  ) async {
    if (phase == 'organize') await _barrier(root);
    return const AudioOrganizedNote(title: '恢复记录', text: '保留原件并恢复同一笔记。');
  }
}

class _BarrierPublisher extends AtomicNoteFilePublisher {
  _BarrierPublisher(this.root);
  final String root;
  @override
  Future<void> publish({
    required File destination,
    required File staging,
    required String text,
  }) async {
    await super.publish(destination: destination, staging: staging, text: text);
    if (destination.path.endsWith('.md')) await _barrier(root);
  }
}
