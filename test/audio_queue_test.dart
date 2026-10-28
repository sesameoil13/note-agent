import 'dart:io';
import 'dart:async';
import 'dart:convert';
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
    expect(saved.processingReason, contains('未连接'));
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
  test('processing checkpoints survive reopen and note export retry without a second note', () async {
    final root = await Directory.systemTemp.createTemp(
      'note-agent-audio-process-',
    );
    addTearDown(() => root.delete(recursive: true));
    final local = Directory('${root.path}/local');
    final vault = await Directory('${root.path}/vault').create();
    final source = await File('${root.path}/voice.wav')
        .writeAsBytes(wave(), flush: true);
    final service = await _ProcessingService.start();
    addTearDown(service.close);
    var now = DateTime.utc(2026, 10, 17);
    var workspace = await NoteWorkspace.open(
      localDirectory: local,
      vaultDirectory: vault,
      audioProcessor: _LoopbackProcessor(service.uri),
      clock: () => now,
    );
    final imported = await workspace.importAudio(
      original: source,
      submissionId: 'process-1',
    );
    service.transcriptionGate = Completer<void>();
    final running = workspace.resumePendingAudioProcessing();
    await service.transcriptionStarted.future;
    expect(
      workspace.audioSources.single.processingStatus,
      AudioProcessingStatus.processing,
    );
    // A blocked network boundary must not serialize all workspace mutations.
    await workspace.captureText(title: '同时收集', text: '独立的原文。');
    expect(workspace.notes.single.title, '同时收集');
    service.transcriptionGate!.complete();
    service.organizingFailure = AudioProcessingFailureKind.recoverable;
    await running;
    final waiting = workspace.audioSources.single;
    expect(waiting.transcript, '完整原话，不能被整理正文替代。');
    expect(waiting.processingStatus, AudioProcessingStatus.pending);
    expect(waiting.automaticRetries, 1);
    expect(waiting.nextAttemptAt, now.add(const Duration(seconds: 5)));
    await workspace.close();
    service.organizingFailure = null;
    service.transcriptText = '不应再次转写';
    now = now.add(const Duration(seconds: 5));
    workspace = await NoteWorkspace.open(
      localDirectory: local,
      vaultDirectory: vault,
      audioProcessor: _LoopbackProcessor(service.uri),
      clock: () => now,
    );
    addTearDown(workspace.close);
    await workspace.resumePendingAudioProcessing();
    expect(
      workspace.audioSources.single.processingStatus,
      AudioProcessingStatus.completed,
    );
    expect(workspace.audioSources.single.id, imported.id);
    final note = workspace.notes.singleWhere(
      (n) => n.id == imported.outputNoteId,
    );
    expect(note.text, '整理后的正文。');
    expect(await File(note.sourcePath).readAsString(), '完整原话，不能被整理正文替代。');
    expect(await File(note.notePath).readAsString(), contains('[完整转写]'));
    await workspace.retryAudioProcessing(imported.id);
    await workspace.resumePendingAudioProcessing();
    expect(
      workspace.notes.where((n) => n.id == imported.outputNoteId),
      hasLength(1),
    );
    expect(workspace.audioSources.single.transcript, '完整原话，不能被整理正文替代。');
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
    await workspace.resumePendingAudioProcessing();
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
    final service = await _ProcessingService.start();
    addTearDown(service.close);
    final workspace = await NoteWorkspace.open(
      localDirectory: Directory('${root.path}/local'),
      vaultDirectory: await Directory('${root.path}/vault').create(),
      audioProcessor: _LoopbackProcessor(service.uri),
    );
    addTearDown(workspace.close);
    final file = await File('${root.path}/long.wav')
        .writeAsBytes(wave(seconds: 660), flush: true);
    final saved = await workspace.importAudio(
      original: file,
      submissionId: 'long',
    );
    await workspace.resumePendingAudioProcessing();
    final refused = workspace.audioSources.single;
    expect(service.transcriptionStarted.isCompleted, isFalse);
    expect(refused.processingStatus, AudioProcessingStatus.failed);
    expect(refused.processingReason, contains('5 分钟'));
    expect(refused.originalSaved, isTrue);
    expect(await File(saved.originalPath).length(), 10560044);
    expect(refused.publicationStatus, AudioPublicationStatus.exceedsFileLimit);
    expect(await File(refused.sourcePath).exists(), isFalse);
    // A manual retry cannot undo the refusal.
    await workspace.retryAudioProcessing(refused.id);
    expect(service.transcriptionStarted.isCompleted, isFalse);
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

  test('three automatic retries persist across restarts then manual retry keeps the output identity', () async {
    final root = await Directory.systemTemp.createTemp(
      'note-agent-audio-retry-',
    );
    addTearDown(() => root.delete(recursive: true));
    final local = Directory('${root.path}/local');
    final vault = await Directory('${root.path}/vault').create();
    final file = await File('${root.path}/retry.wav')
        .writeAsBytes(wave(), flush: true);
    final service = await _ProcessingService.start();
    addTearDown(service.close);
    service.organizingFailure = AudioProcessingFailureKind.recoverable;
    var now = DateTime.utc(2026, 10, 17);
    var workspace = await NoteWorkspace.open(
      localDirectory: local,
      vaultDirectory: vault,
      audioProcessor: _LoopbackProcessor(service.uri),
      clock: () => now,
    );
    final saved = await workspace.importAudio(
      original: file,
      submissionId: 'retry',
    );
    for (var attempt = 1; attempt <= 4; attempt++) {
      await workspace.resumePendingAudioProcessing();
      final current = workspace.audioSources.single;
      expect(current.attempts, attempt);
      if (attempt < 4) {
        expect(current.processingStatus, AudioProcessingStatus.pending);
        expect(current.automaticRetries, attempt);
        // Network/resume events before the persisted deadline do not retry.
        await workspace.resumePendingAudioProcessing();
        expect(workspace.audioSources.single.attempts, attempt);
        now = current.nextAttemptAt!;
        await workspace.close();
        workspace = await NoteWorkspace.open(
          localDirectory: local,
          vaultDirectory: vault,
          audioProcessor: _LoopbackProcessor(service.uri),
          clock: () => now,
        );
      }
    }
    expect(
      workspace.audioSources.single.processingStatus,
      AudioProcessingStatus.failed,
    );
    expect(workspace.audioSources.single.automaticRetries, 3);
    now = now.add(const Duration(days: 1));
    await workspace.resumePendingAudioProcessing();
    expect(workspace.audioSources.single.attempts, 4);
    service.organizingFailure = null;
    await workspace.retryAudioProcessing(saved.id);
    expect(
      workspace.audioSources.single.processingStatus,
      AudioProcessingStatus.completed,
    );
    expect(workspace.notes.single.id, saved.outputNoteId);
    await workspace.retryAudioProcessing(saved.id);
    expect(workspace.notes, hasLength(1));
    await workspace.close();
  });

  for (final kind in [
    AudioProcessingFailureKind.credentials,
    AudioProcessingFailureKind.balance,
    AudioProcessingFailureKind.budget,
    AudioProcessingFailureKind.outcomeUnknown,
  ]) {
    test(
      '$kind stops automatic requests until an explicit manual retry',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'note-agent-audio-stop-',
        );
        addTearDown(() => root.delete(recursive: true));
        final service = await _ProcessingService.start();
        addTearDown(service.close);
        service.organizingFailure = kind;
        var now = DateTime.utc(2026, 10, 17);
        final workspace = await NoteWorkspace.open(
          localDirectory: Directory('${root.path}/local'),
          vaultDirectory: await Directory('${root.path}/vault').create(),
          audioProcessor: _LoopbackProcessor(service.uri),
          clock: () => now,
        );
        addTearDown(workspace.close);
        final source = await workspace.importAudio(
          original: await File('${root.path}/voice.wav').writeAsBytes(wave()),
          submissionId: 'stop',
        );
        await workspace.resumePendingAudioProcessing();
        expect(
          workspace.audioSources.single.processingStatus,
          AudioProcessingStatus.failed,
        );
        expect(workspace.audioSources.single.nextAttemptAt, isNull);
        now = now.add(const Duration(days: 1));
        await workspace.resumePendingAudioProcessing();
        expect(workspace.audioSources.single.attempts, 1);
        service.organizingFailure = null;
        await workspace.retryAudioProcessing(source.id);
        expect(workspace.notes.single.id, source.outputNoteId);
      },
    );
  }

  test('close checkpoints a blocked processor and a late response cannot overwrite the reopened job', () async {
    final root = await Directory.systemTemp.createTemp(
      'note-agent-audio-close-',
    );
    addTearDown(() => root.delete(recursive: true));
    final service = await _ProcessingService.start();
    addTearDown(service.close);
    final local = Directory('${root.path}/local');
    final vault = await Directory('${root.path}/vault').create();
    final workspace = await NoteWorkspace.open(
      localDirectory: local,
      vaultDirectory: vault,
      audioProcessor: _LoopbackProcessor(service.uri),
    );
    final source = await workspace.importAudio(
      original: await File('${root.path}/close.wav').writeAsBytes(wave()),
      submissionId: 'close',
    );
    service.transcriptText = '过期回调';
    final oldGate = service.transcriptionGate = Completer<void>();
    final oldWork = workspace.resumePendingAudioProcessing();
    await service.transcriptionStarted.future;
    await workspace.close().timeout(const Duration(seconds: 1));
    service.transcriptionGate = null;
    service.transcriptText = '重新打开后的完整转写';
    final reopened = await NoteWorkspace.open(
      localDirectory: local,
      vaultDirectory: vault,
      audioProcessor: _LoopbackProcessor(service.uri),
    );
    addTearDown(reopened.close);
    await reopened.resumePendingAudioProcessing();
    expect(reopened.audioSources.single.transcript, '重新打开后的完整转写');
    oldGate.complete();
    await oldWork;
    expect(
      reopened.audioSources.single.processingStatus,
      AudioProcessingStatus.completed,
    );
    expect(reopened.audioSources.single.transcript, '重新打开后的完整转写');
    expect(reopened.notes.single.id, source.outputNoteId);
  });
  test('uncertain Markdown publication replays saved results without an available processor', () async {
    final root = await Directory.systemTemp.createTemp(
      'note-agent-audio-publish-',
    );
    addTearDown(() => root.delete(recursive: true));
    final service = await _ProcessingService.start();
    addTearDown(service.close);
    final local = Directory('${root.path}/local');
    final vault = await Directory('${root.path}/vault').create();
    var now = DateTime.utc(2026, 10, 17);
    final workspace = await NoteWorkspace.open(
      localDirectory: local,
      vaultDirectory: vault,
      audioProcessor: _LoopbackProcessor(service.uri),
      filePublisher: _CommitThenFailPublisher(),
      clock: () => now,
    );
    final source = await workspace.importAudio(
      original: await File('${root.path}/publish.wav').writeAsBytes(wave()),
      submissionId: 'publish',
    );
    await workspace.resumePendingAudioProcessing();
    expect(workspace.notes.single.status, NoteStatus.exportFailed);
    expect(workspace.audioSources.single.stage, 'materialize');
    expect(
      workspace.audioSources.single.processingStatus,
      AudioProcessingStatus.pending,
    );
    expect(await File(workspace.notes.single.notePath).exists(), isTrue);
    await workspace.close();
    now = now.add(const Duration(seconds: 5));
    final reopened = await NoteWorkspace.open(
      localDirectory: local,
      vaultDirectory: vault,
      clock: () => now,
    );
    addTearDown(reopened.close);
    await reopened.resumePendingAudioProcessing();
    expect(
      reopened.audioSources.single.processingStatus,
      AudioProcessingStatus.completed,
    );
    expect(reopened.notes.single.id, source.outputNoteId);
    expect(reopened.notes.single.originalText, '完整原话，不能被整理正文替代。');
    expect(await vault.list().where((f) => f.path.endsWith('.md')).length, 1);
  });

  test('an interrupted adapter without replay guarantees stays failed after reopen', () async {
    final root = await Directory.systemTemp.createTemp(
      'note-agent-audio-unknown-',
    );
    addTearDown(() => root.delete(recursive: true));
    final service = await _ProcessingService.start();
    addTearDown(service.close);
    final local = Directory('${root.path}/local');
    final vault = await Directory('${root.path}/vault').create();
    final workspace = await NoteWorkspace.open(
      localDirectory: local,
      vaultDirectory: vault,
      audioProcessor: _LoopbackProcessor(service.uri, safeReplay: false),
    );
    await workspace.importAudio(
      original: await File('${root.path}/unknown.wav').writeAsBytes(wave()),
      submissionId: 'unknown',
    );
    final gate = service.transcriptionGate = Completer<void>();
    final interrupted = workspace.resumePendingAudioProcessing();
    await service.transcriptionStarted.future;
    await workspace.close();
    final reopened = await NoteWorkspace.open(
      localDirectory: local,
      vaultDirectory: vault,
    );
    addTearDown(reopened.close);
    expect(
      reopened.audioSources.single.processingStatus,
      AudioProcessingStatus.failed,
    );
    expect(reopened.audioSources.single.processingReason, contains('结果未确认'));
    expect(reopened.audioSources.single.nextAttemptAt, isNull);
    gate.complete();
    await interrupted;
    await reopened.resumePendingAudioProcessing();
    expect(reopened.audioSources.single.attempts, 1);
    expect(reopened.notes, isEmpty);
  });
  test('the real backoff timer resumes a recoverable job without another user action', () async {
    final root = await Directory.systemTemp.createTemp(
      'note-agent-audio-timer-',
    );
    addTearDown(() => root.delete(recursive: true));
    final service = await _ProcessingService.start();
    addTearDown(service.close);
    service.organizingFailure = AudioProcessingFailureKind.recoverable;
    final workspace = await NoteWorkspace.open(
      localDirectory: Directory('${root.path}/local'),
      vaultDirectory: await Directory('${root.path}/vault').create(),
      audioProcessor: _LoopbackProcessor(service.uri),
    );
    addTearDown(workspace.close);
    await workspace.importAudio(
      original: await File('${root.path}/timer.wav').writeAsBytes(wave()),
      submissionId: 'timer',
    );
    await workspace.resumePendingAudioProcessing();
    expect(workspace.audioSources.single.nextAttemptAt, isNotNull);
    service.organizingFailure = null;
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (workspace.audioSources.single.processingStatus !=
            AudioProcessingStatus.completed &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    expect(
      workspace.audioSources.single.processingStatus,
      AudioProcessingStatus.completed,
    );
    expect(workspace.audioSources.single.attempts, 2);
    expect(workspace.notes, hasLength(1));
  });
  test('original publication failure does not block processing and its repaired source link stays truthful', () async {
    final root = await Directory.systemTemp.createTemp(
      'note-agent-audio-source-export-',
    );
    addTearDown(() => root.delete(recursive: true));
    final service = await _ProcessingService.start();
    addTearDown(service.close);
    final storage = _BinaryFailureVault(
      await Directory('${root.path}/vault').create(),
    );
    final workspace = await NoteWorkspace.open(
      localDirectory: Directory('${root.path}/local'),
      vaultStorage: storage,
      audioProcessor: _LoopbackProcessor(service.uri),
    );
    addTearDown(workspace.close);
    final source = await workspace.importAudio(
      original: await File('${root.path}/source.wav').writeAsBytes(wave()),
      submissionId: 'source',
    );
    expect(source.originalSaved, isTrue);
    expect(source.publicationStatus, AudioPublicationStatus.failed);
    await workspace.resumePendingAudioProcessing();
    expect(
      workspace.audioSources.single.processingStatus,
      AudioProcessingStatus.completed,
    );
    final note = workspace.notes.single;
    expect(note.status, NoteStatus.localSaved);
    expect(await File(note.notePath).readAsString(), contains('笔记库写入'));
    expect(await File(note.notePath).readAsString(), isNot(contains('仅本机保留')));
    storage.fail = false;
    await workspace.retryAudioSourceExport(source.id);
    expect(
      workspace.audioSources.single.publicationStatus,
      AudioPublicationStatus.published,
    );
    expect(await File(source.sourcePath).readAsBytes(), wave());
    expect(await File(note.notePath).readAsString(), contains('[source.wav]'));
    expect(workspace.notes.single.id, note.id);
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

class _LoopbackProcessor implements AudioProcessor {
  _LoopbackProcessor(this.uri, {this.safeReplay = true});
  final bool safeReplay;
  final Uri uri;
  @override
  bool get canReplayInterruptedRequests => safeReplay;
  Future<Map<String, dynamic>> _post(
    String stage,
    AudioProcessingRequest request,
  ) async {
    final client = HttpClient();
    try {
      final outgoing = await client.postUrl(uri.resolve(stage));
      outgoing.headers.contentType = ContentType.json;
      outgoing.write(
        jsonEncode({'jobId': request.sourceId, 'attemptId': request.attemptId}),
      );
      final incoming = await outgoing.close();
      final data = jsonDecode(
        await utf8.decoder.bind(incoming).join(),
      ) as Map<String, dynamic>;
      if (incoming.statusCode != 200) {
        throw AudioProcessingFailure(
          AudioProcessingFailureKind.values.byName(data['kind'] as String),
          data['error'] as String,
        );
      }
      return data;
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<AudioTranscript> transcribe(AudioProcessingRequest request) async =>
      AudioTranscript((await _post('transcribe', request))['text'] as String);
  @override
  Future<AudioOrganizedNote> organize(
    AudioProcessingRequest request,
    AudioTranscript transcript,
  ) async {
    final result = await _post('organize', request);
    return AudioOrganizedNote(
      title: result['title'] as String,
      text: result['text'] as String,
    );
  }
}

class _ProcessingService {
  _ProcessingService(this.server);
  final HttpServer server;
  Uri get uri => Uri.parse('http://127.0.0.1:${server.port}/');
  final transcriptionStarted = Completer<void>();
  Completer<void>? transcriptionGate;
  AudioProcessingFailureKind? organizingFailure;
  String transcriptText = '完整原话，不能被整理正文替代。';
  static Future<_ProcessingService> start() async {
    final service = _ProcessingService(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    service.server.listen(service._respond);
    return service;
  }

  Future<void> _respond(HttpRequest request) async {
    await request.drain<void>();
    if (request.uri.path == '/transcribe') {
      if (!transcriptionStarted.isCompleted) transcriptionStarted.complete();
      final text = transcriptText;
      await transcriptionGate?.future;
      request.response.write(jsonEncode({'text': text}));
    } else if (organizingFailure != null) {
      request.response.statusCode = 503;
      request.response.write(
        jsonEncode({'kind': organizingFailure!.name, 'error': '处理服务暂时失败'}),
      );
    } else {
      request.response.write(jsonEncode({'title': '会议记录', 'text': '整理后的正文。'}));
    }
    await request.response.close();
  }

  Future<void> close() => server.close(force: true);
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

class _CommitThenFailPublisher extends AtomicNoteFilePublisher {
  bool failed = false;
  @override
  Future<void> publish({
    required File destination,
    required File staging,
    required String text,
  }) async {
    await super.publish(destination: destination, staging: staging, text: text);
    if (!failed && destination.path.endsWith('.md')) {
      failed = true;
      throw const FileSystemException(
        'Simulated lost Markdown acknowledgement',
      );
    }
  }
}

class _BinaryFailureVault extends DirectoryVaultStorage {
  _BinaryFailureVault(super.directory);
  bool fail = true;
  @override
  Future<void> publishFile(
    String relativePath,
    File original,
    String operationId,
  ) async {
    if (fail) throw const FileSystemException('原件笔记库写入未确认');
    return super.publishFile(relativePath, original, operationId);
  }
}
