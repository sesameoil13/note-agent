import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/note_workspace.dart';

import 'support/budget_fixture.dart';
import 'audio_queue_test.dart' show wave;

void main() {
  test('one consent transcribes then organizes with both templates and durable full sources', () async {
    final f = BudgetFixture();
    await f.start();
    addTearDown(f.close);
    final w = f.workspaces.first;
    final original = await File('${f.root.path}/synthetic.wav')
        .writeAsBytes(wave());
    final source = await w.importAudio(
      original: original,
      submissionId: 'synthetic-one',
    );
    await w.resumePendingAudioProcessing();
    expect(f.audioRequests, 0);
    expect(f.modelRequests, isEmpty);
    final prepared = await w.prepareAudioProcessing(source.id);
    expect(prepared.estimatedCnyMicros, greaterThan(0));
    expect(prepared.description, contains('不保证远端价格封顶'));
    expect(f.audioRequests, 0);
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
    await w.confirmAudioProcessing(source.id);
    expect(f.audioRequests, 1);
    expect(f.modelRequests, hasLength(1));
    expect(f.lastAudioRequest!['model'], 'openai/whisper-large-v3-turbo');
    expect(f.lastAudioRequest!['input_audio']['format'], 'wav');
    expect(f.lastAudioRequest!.containsKey('provider'), false);
    final note = w.notes.single;
    expect(note.kind, NoteKind.todo);
    expect(note.originalText, f.transcript);
    expect(await File(note.sourcePath).readAsString(), f.transcript);
    final md = await File(note.notePath).readAsString();
    expect(md, contains('## 待办'));
    expect(md, contains('## 摘要'));
    expect(md, contains('[完整转写]'));
    expect(md, contains('synthetic.wav'));
    expect(await File(source.originalPath).readAsBytes(), wave());
    await f.reopen(0);
    await f.workspaces.first.resumePendingAudioProcessing();
    expect(f.audioRequests, 1);
    expect(f.modelRequests, hasLength(1));
    expect(f.workspaces.first.notes.single.originalText, f.transcript);
  });
  test('missing STT receipt preserves full transcript and unknown hold, without organizing or replay', () async {
    final f = BudgetFixture();
    await f.start();
    addTearDown(f.close);
    f.omitAudioCost = true;
    f.omitAudioId = true;
    final w = f.workspaces.first;
    final source = await w.importAudio(
      original: await File('${f.root.path}/synthetic.wav').writeAsBytes(wave()),
      submissionId: 'missing-receipt',
    );
    await w.prepareAudioProcessing(source.id);
    await w.confirmAudioProcessing(source.id);
    expect(w.audioJobs.single.status, AudioJobStatus.paused);
    expect(w.notes.single.originalText, f.transcript);
    expect(w.budget.unknownCnyMicros, greaterThan(0));
    expect(f.modelRequests, isEmpty);
    await f.reopen(0);
    await f.workspaces.first.confirmAudioProcessing(source.id);
    await f.workspaces.first.reconcileAudioProcessing(source.id);
    expect(f.audioRequests, 1);
    expect(f.modelRequests, isEmpty);
    expect(f.workspaces.first.budget.unknownCnyMicros, greaterThan(0));
  });
  test('oversized complete transcript remains findable and is never silently truncated or sent', () async {
    final f = BudgetFixture();
    await f.start();
    addTearDown(f.close);
    f.transcript = List.filled(10000, '记录').join();
    final w = f.workspaces.first;
    final source = await w.importAudio(
      original: await File('${f.root.path}/synthetic.wav').writeAsBytes(wave()),
      submissionId: 'large-transcript',
    );
    await w.prepareAudioProcessing(source.id);
    await w.confirmAudioProcessing(source.id);
    expect(w.audioJobs.single.status, AudioJobStatus.paused);
    expect(w.audioJobs.single.message, contains('超过'));
    expect(w.notes.single.originalText, f.transcript);
    expect(await File(w.notes.single.sourcePath).readAsString(), f.transcript);
    expect(f.modelRequests, isEmpty);
    expect(w.budget.reservedCnyMicros, 0);
  });
  test('changed private original after prepare rejects upload and releases only unsent funds', () async {
    final f = BudgetFixture();
    await f.start();
    addTearDown(f.close);
    final w = f.workspaces.first;
    final source = await w.importAudio(
      original: await File('${f.root.path}/synthetic.wav').writeAsBytes(wave()),
      submissionId: 'changed-audio',
    );
    await w.prepareAudioProcessing(source.id);
    final bytes = wave();
    bytes[50] = bytes[50] ^ 255;
    await File(source.originalPath).writeAsBytes(bytes);
    await w.confirmAudioProcessing(source.id);
    expect(w.audioJobs.single.status, AudioJobStatus.paused);
    expect(f.audioRequests, 0);
    expect(f.modelRequests, isEmpty);
    expect(w.budget.reservedCnyMicros, 0);
  });
  test(
    'concurrent confirms share one dispatch and cancellation never uploads',
    () async {
      final f = BudgetFixture();
      await f.start();
      addTearDown(f.close);
      final w = f.workspaces.first;
      final file = await File('${f.root.path}/synthetic.wav')
          .writeAsBytes(wave());
      final source = await w.importAudio(
        original: file,
        submissionId: 'concurrent-audio',
      );
      await w.prepareAudioProcessing(source.id);
      await Future.wait([
        w.confirmAudioProcessing(source.id),
        w.confirmAudioProcessing(source.id),
      ]);
      expect(f.audioRequests, 1);
      expect(f.modelRequests, hasLength(1));
      final next = await w.importAudio(
        original: file,
        submissionId: 'cancelled-audio',
      );
      await w.prepareAudioProcessing(next.id);
      await w.cancelAudioProcessing(next.id);
      await w.confirmAudioProcessing(next.id);
      expect(f.audioRequests, 1);
      expect(f.modelRequests, hasLength(1));
      expect(w.budget.reservedCnyMicros, 0);
    },
  );
  test('manual organization retry reuses durable transcript without a second audio upload', () async {
    final f = BudgetFixture();
    await f.start();
    addTearDown(f.close);
    f.modelStatuses.add(503);
    final w = f.workspaces.first;
    final source = await w.importAudio(
      original: await File('${f.root.path}/synthetic.wav').writeAsBytes(wave()),
      submissionId: 'retry-stage',
    );
    await w.prepareAudioProcessing(source.id);
    await w.confirmAudioProcessing(source.id);
    expect(w.audioJobs.single.status, AudioJobStatus.paused);
    expect(f.audioRequests, 1);
    expect(f.modelRequests, hasLength(1));
    final previousHold = w.budget.unknownCnyMicros;
    expect(previousHold, greaterThan(0));
    await w.prepareAudioOrganization(source.id);
    expect(f.audioRequests, 1);
    expect(f.modelRequests, hasLength(1));
    await w.confirmAudioProcessing(source.id);
    expect(f.audioRequests, 1);
    expect(f.modelRequests, hasLength(2));
    expect(w.notes, hasLength(1));
    expect(w.notes.single.originalText, f.transcript);
    expect(w.budget.unknownCnyMicros, previousHold);
  });
  test('explicit upload retry gets new holds while a failed upload remains unknown across restart', () async {
    final f = BudgetFixture();
    await f.start();
    addTearDown(f.close);
    f.audioStatus = 503;
    final w = f.workspaces.first;
    final source = await w.importAudio(
      original: await File('${f.root.path}/synthetic.wav').writeAsBytes(wave()),
      submissionId: 'upload-retry',
    );
    await w.prepareAudioProcessing(source.id);
    await w.confirmAudioProcessing(source.id);
    expect(f.audioRequests, 1);
    expect(f.modelRequests, isEmpty);
    final unknown = w.budget.unknownCnyMicros;
    expect(unknown, greaterThan(0));
    await f.reopen(0);
    final reopened = f.workspaces.first;
    await reopened.resumePendingAudioProcessing();
    expect(f.audioRequests, 1);
    f.audioStatus = 200;
    await reopened.prepareAudioRetry(source.id);
    expect(reopened.audioJobs.single.status, AudioJobStatus.prepared);
    expect(f.audioRequests, 1);
    expect(reopened.budget.unknownCnyMicros, unknown);
    await reopened.confirmAudioProcessing(source.id);
    expect(f.audioRequests, 2);
    expect(f.modelRequests, hasLength(1));
    expect(reopened.budget.unknownCnyMicros, unknown);
    expect(reopened.notes, hasLength(1));
  });
}
