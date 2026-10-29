import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/note_workspace.dart';
import 'package:sqlite3/sqlite3.dart';

import 'audio_queue_test.dart' show wave;
import 'support/ai_fixture.dart';

/// Automatic 整理 (GLOSSARY) of recordings and imported audio: transcribed by
/// qwen3-asr-flash, then organized by qwen-plus, with no estimate,
/// confirmation or budget request (ADR 0004).
void main() {
  late AiFixture f;
  setUp(() => f = AiFixture());
  tearDown(() => f.close());

  Future<WorkspaceAudioSource> importWave(int seconds, String id) async =>
      f.workspaces.first.importAudio(
        original: await File('${f.root.path}/$id.wav')
            .writeAsBytes(wave(seconds: seconds)),
        submissionId: id,
      );

  Iterable<String> budgetPaths() =>
      f.workerPaths.where((p) => p.startsWith('/v1/budget'));

  String sentText(Map<String, dynamic> request) =>
      (jsonDecode((request['messages'] as List).last['content'] as String)
              as Map)['text']
          as String;

  test(
    'a stopped recording is transcribed and organized with no confirm call',
    () async {
      f.recorder = _WaveRecorder(seconds: 20);
      await f.start();
      final w = f.workspaces.first;
      await w.startRecording();
      final recording = await w.stopRecording();
      final noteId = w.audioSources.single.outputNoteId;
      expect(w.organizeStatus(noteId), OrganizeStatus.waiting);

      await w.sendWaitingNow();

      expect(w.organizeStatus(noteId), OrganizeStatus.organized);
      expect(f.audioRequests, hasLength(1));
      expect(f.audioRequests.single['model'], 'qwen3-asr-flash');
      expect(f.audioSeconds, [20]);
      expect(f.modelRequests, hasLength(1));
      expect(sentText(f.modelRequests.single), f.transcript);
      final note = w.notes.single;
      expect(note.id, noteId);
      expect(note.title, '记录想法');
      expect(note.text, '整理后的普通想法。');
      expect(note.originalText, f.transcript);
      expect(await File(note.sourcePath).readAsString(), f.transcript);
      expect(
        await File(recording.originalPath).readAsBytes(),
        wave(seconds: 20),
      );
      expect(budgetPaths(), isEmpty);

      // Organized: never sent again, also after reopening.
      await f.reopen(0);
      await f.workspaces.first.sendWaitingNow();
      expect(f.audioRequests, hasLength(1));
      expect(f.modelRequests, hasLength(1));
    },
  );

  test(
    'imported audio shows 转写中 while transcribing and 整理中 while organizing',
    () async {
      await f.start();
      final w = f.workspaces.first;
      final source = await importWave(4, 'imported');
      expect(w.organizeStatus(source.outputNoteId), OrganizeStatus.waiting);
      OrganizeStatus? transcribing, organizing;
      f.beforeAudioReply = () async =>
          transcribing = w.organizeStatus(source.outputNoteId);
      f.beforeReply = () async =>
          organizing = w.organizeStatus(source.outputNoteId);

      await w.sendWaitingNow();

      expect(transcribing!.label, '转写中');
      expect(organizing!.label, '整理中');
      expect(w.organizeStatus(source.outputNoteId)!.label, '已整理');
      final md = await File(w.notes.single.notePath).readAsString();
      expect(md, contains('[完整转写]'));
      expect(md, contains('imported.wav'));
      expect(budgetPaths(), isEmpty);
    },
  );

  test(
    'a five-minute recording is sent as two parts in order and joined',
    () async {
      f.partTranscripts.addAll(['第一段内容。', '第二段内容。']);
      await f.start();
      final w = f.workspaces.first;
      final source = await importWave(300, 'long');

      await w.sendWaitingNow();

      expect(f.audioSeconds, [150, 150]);
      expect(f.modelRequests, hasLength(1));
      expect(sentText(f.modelRequests.single), '第一段内容。第二段内容。');
      expect(w.organizeStatus(source.outputNoteId), OrganizeStatus.organized);
      expect(w.notes.single.originalText, '第一段内容。第二段内容。');
    },
  );

  test(
    'a part that arrived is not sent again when the capture is retried',
    () async {
      f.partTranscripts.addAll(['第一段内容。', '第二段内容。']);
      f.audioStatuses.addAll([200, 503]);
      await f.start();
      final w = f.workspaces.first;
      final source = await importWave(300, 'retry');

      await w.sendWaitingNow();
      expect(w.organizeStatus(source.outputNoteId), OrganizeStatus.failed);
      expect(f.audioRequests, hasLength(2));
      expect(f.modelRequests, isEmpty);

      await f.reopen(0);
      final again = f.workspaces.first;
      final failure = again.processingFailures.single;
      expect(failure.noteId, source.outputNoteId);
      await again.recoverProcessingFailure(failure.id);

      expect(f.audioSeconds, [150, 150, 150]);
      expect(f.modelRequests, hasLength(1));
      expect(sentText(f.modelRequests.single), '第一段内容。第二段内容。');
      expect(
        again.organizeStatus(source.outputNoteId),
        OrganizeStatus.organized,
      );
    },
  );

  test('a transcript that arrived is kept when organizing fails, and a retry only organizes', () async {
    f.modelStatuses.add(503);
    await f.start();
    final w = f.workspaces.first;
    final source = await importWave(4, 'organize-fails');

    await w.sendWaitingNow();
    expect(w.organizeStatus(source.outputNoteId), OrganizeStatus.failed);
    expect(w.notes.single.originalText, f.transcript);

    await w.recoverProcessingFailure(w.processingFailures.single.id);

    expect(f.audioRequests, hasLength(1));
    expect(f.modelRequests, hasLength(2));
    expect(w.organizeStatus(source.outputNoteId), OrganizeStatus.organized);
    expect(w.notes.single.text, '整理后的普通想法。');
  });

  test('captures are sent oldest first, audio and text alike', () async {
    await f.start();
    final w = f.workspaces.first;
    await w.captureText(title: '先', text: '先收集的文字。');
    await importWave(4, 'middle');
    await w.captureText(title: '后', text: '后收集的文字。');

    await w.sendWaitingNow();

    expect(f.modelRequests.map(sentText), ['先收集的文字。', f.transcript, '后收集的文字。']);
  });

  test('only the capturing device sends audio', () async {
    await f.start();
    final source = await importWave(4, 'one-device');

    await f.workspaces[1].sendWaitingNow();
    expect(f.audioRequests, isEmpty);
    expect(f.workspaces[1].organizeStatus(source.outputNoteId), isNull);
  });

  test(
    'each part is sent inline as qwen3-asr-flash with digits kept as said',
    () async {
      await f.start();
      await importWave(4, 'shape');

      await f.workspaces.first.sendWaitingNow();

      final request = f.audioRequests.single;
      final content = ((request['messages'] as List).single as Map)['content'];
      final audio = ((content as List).single as Map)['input_audio'] as Map;
      expect(audio['data'], startsWith('data:audio/wav;base64,'));
      expect(
        base64Decode((audio['data'] as String).split(',').last),
        wave(seconds: 4),
      );
      expect((request['asr_options'] as Map)['enable_itn'], isFalse);
    },
  );

  test('a recording about an action becomes a to-do note with its reminder and full sources', () async {
    await f.start();
    final w = f.workspaces.first;
    f.modelResult = {
      'kind': 'todo',
      'title': '整理会议记录',
      'body': '整理会议记录。',
      'actions': [
        {
          'text': '整理会议记录',
          'reason': 'none',
          'timeExpression': '明天下午两点',
          'timeStatus': 'explicit',
        },
      ],
    };
    final source = await importWave(4, 'todo');

    await w.sendWaitingNow();

    final note = w.notes.single;
    expect(note.kind, NoteKind.todo);
    final reminder = w.reminders.single;
    expect(reminder.actionId, note.actions.single.id);
    final collected = note.createdAt.toLocal();
    expect(
      reminder.time,
      DateTime(collected.year, collected.month, collected.day + 1, 14),
    );
    final md = await File(note.notePath).readAsString();
    expect(md, contains('## 待办'));
    expect(md, contains('[完整转写]'));
    expect(await File(source.originalPath).readAsBytes(), wave(seconds: 4));
  });

  test('association context yields space to the complete transcript, and unsent candidates never become links', () async {
    await f.start();
    final w = f.workspaces.first;
    for (var i = 0; i < 12; i++) {
      await w.captureText(
        title: '体验设计$i',
        text: List.filled(200, '用户访谈与首次使用体验。').join(),
      );
    }
    // Left unorganized, so each candidate keeps its long text.
    f.modelStatuses.addAll(List.filled(12, 400));
    await w.sendWaitingNow();
    f.modelRequests.clear();
    f.transcript = List.filled(250, '用户访谈记录首次使用体验。').join();
    final source = await importWave(4, 'bounded');
    f.beforeReply = () async {
      final input = jsonDecode(
        (f.modelRequests.last['messages'] as List).last['content'] as String,
      ) as Map;
      final sent = (input['associationCandidates'] as List)
          .map((c) => c['noteId'])
          .toSet();
      final omitted = w.notes.firstWhere(
        (n) => n.id != source.outputNoteId && !sent.contains(n.id),
      );
      f.modelResult = {
        'manifestVersion': 3,
        'kind': 'ordinary',
        'title': '错误关联',
        'body': '此结果不得覆盖原文。',
        'actions': [],
        'associations': [
          {'noteId': omitted.id, 'reason': '未发送候选不得成为链接。'},
        ],
        'newTopics': [],
      };
    };

    await w.sendWaitingNow();

    final request = f.modelRequests.single;
    expect(utf8.encode(jsonEncode(request)).length, lessThanOrEqualTo(20000));
    final input = jsonDecode(
      (request['messages'] as List).last['content'] as String,
    ) as Map;
    expect(input['text'], f.transcript);
    expect(
      (input['associationCandidates'] as List).length,
      inInclusiveRange(1, 11),
    );
    final note = w.notes.firstWhere((n) => n.id == source.outputNoteId);
    expect(note.associations, isEmpty);
    expect(note.text, f.transcript);
    // An invented link is rejected; the capture keeps its transcript.
    expect(w.organizeStatus(source.outputNoteId), OrganizeStatus.failed);
    expect(w.organizeMessage(source.outputNoteId), contains('原文保留'));
  });

  test(
    'a transcript too long to organize is kept and never truncated or sent',
    () async {
      await f.start();
      f.transcript = List.filled(10000, '记录').join();
      final w = f.workspaces.first;
      final source = await importWave(4, 'oversized');

      await w.sendWaitingNow();

      expect(w.organizeStatus(source.outputNoteId), OrganizeStatus.failed);
      expect(w.organizeMessage(source.outputNoteId), contains('超过'));
      expect(f.modelRequests, isEmpty);
      expect(w.notes.single.originalText, f.transcript);
      expect(
        await File(w.notes.single.sourcePath).readAsString(),
        f.transcript,
      );
    },
  );

  test('an original changed after it was checked is not uploaded', () async {
    await f.start();
    final w = f.workspaces.first;
    final source = await importWave(4, 'changed');
    final bytes = wave(seconds: 4);
    bytes[50] = bytes[50] ^ 255;
    await File(source.originalPath).writeAsBytes(bytes);

    await w.sendWaitingNow();

    expect(w.organizeStatus(source.outputNoteId), OrganizeStatus.failed);
    expect(f.audioRequests, isEmpty);
    expect(f.modelRequests, isEmpty);
  });

  test('on first open after upgrade, old audio jobs are dropped unsent and the audio and transcript stay', () async {
    f.modelStatuses.add(503);
    await f.start();
    final w = f.workspaces.first;
    final transcribed = await importWave(4, 'old-transcribed');
    await w.sendWaitingNow();
    final kept = w.notes.single;
    expect(kept.originalText, f.transcript);
    final estimated = await importWave(4, 'old-estimated');
    await f.reopen(
      0,
      whileClosed: (local) {
        // Stand in for the old app: an estimated job never sent, and one
        // paused after its transcript arrived.
        final db = sqlite3.open('${local.path}/workspace.sqlite3');
        db.execute('DELETE FROM text_jobs');
        for (final (source, status, payload) in [
          (
            estimated,
            'prepared',
            {
              'operation': 'op-old-1',
              'parts': [
                {
                  'index': 0,
                  'attempt': 'op-old-1-audio-0',
                  'state': 'reserved',
                },
              ],
              'textAttempt': 'op-old-1-text',
              'noteId': estimated.outputNoteId,
            },
          ),
          (
            transcribed,
            'paused',
            {
              'operation': 'op-old-2',
              'parts': [
                {'index': 0, 'state': 'done', 'transcript': f.transcript},
              ],
              'transcript': f.transcript,
              'audioSettled': true,
              'consented': true,
              'textAttempt': 'op-old-2-text',
              'noteId': transcribed.outputNoteId,
            },
          ),
        ]) {
          db.execute(
            'INSERT INTO audio_jobs(source_id,vault,status,payload) SELECT ?,vault,?,? FROM audio_queue WHERE id=?',
            [source.id, status, jsonEncode(payload), source.id],
          );
        }
        db.close();
      },
    );
    final reopened = f.workspaces.first;

    await reopened.sendWaitingNow();

    expect(f.audioRequests, hasLength(1));
    expect(f.modelRequests, hasLength(1));
    expect(reopened.processingFailures, isEmpty);
    expect(reopened.organizeStatus(estimated.outputNoteId), isNull);
    expect(reopened.organizeStatus(transcribed.outputNoteId), isNull);
    expect(await File(estimated.originalPath).readAsBytes(), wave(seconds: 4));
    final note = reopened.notes.single;
    expect(note.id, kept.id);
    expect(note.originalText, f.transcript);
    expect(await File(note.sourcePath).readAsString(), f.transcript);
    expect(budgetPaths(), isEmpty);
  });
}

/// A microphone that records a [seconds]-long WAV.
class _WaveRecorder implements AudioPlatform {
  _WaveRecorder({required this.seconds});
  final int seconds;
  AudioCaptureSnapshot snapshot = const AudioCaptureSnapshot(
    phase: AudioCapturePhase.stopped,
    duration: Duration.zero,
  );

  @override
  Future<void> startRecording(String path) async {
    await File(path).writeAsBytes(wave(seconds: seconds), flush: true);
    snapshot = AudioCaptureSnapshot(
      phase: AudioCapturePhase.recording,
      duration: Duration(seconds: seconds),
    );
  }

  @override
  Future<void> pauseRecording() async {}
  @override
  Future<void> resumeRecording() async {}
  @override
  Future<AudioCaptureSnapshot> recordingSnapshot() async => snapshot;
  @override
  Future<AudioCaptureSnapshot> stopRecording() async =>
      snapshot = AudioCaptureSnapshot(
        phase: AudioCapturePhase.stopped,
        duration: snapshot.duration,
      );
  @override
  Future<Duration> inspectRecording(String path) async => snapshot.duration;
  @override
  Future<void> play(String path) async {}
  @override
  Future<void> stopPlayback() async {}
  @override
  Future<AudioPlaybackSnapshot> playbackSnapshot() async =>
      const AudioPlaybackSnapshot(isPlaying: false, position: Duration.zero);
}
