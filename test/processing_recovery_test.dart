import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/note_workspace.dart';

import 'support/budget_fixture.dart';
import 'audio_queue_test.dart' show wave;

void main() {
  test('a text failure after three automatic retries is listed once and recovers manually into the same note', () async {
    final f = BudgetFixture()..modelStatuses.addAll([503, 503, 503, 503]);
    await f.start();
    addTearDown(f.close);
    final w = f.workspaces.first;
    final note = await w.captureText(title: '失败恢复', text: '恢复前的原文。');
    await w.processTextNote(note.id);
    expect(f.modelRequests, hasLength(4));
    final failure = w.processingFailures.single;
    expect(failure.source, ProcessingFailureSource.text);
    expect(failure.noteId, note.id);
    expect(failure.title, '失败恢复');
    expect(failure.recovery, ProcessingRecovery.retry);
    expect(failure.automaticRetriesUsed, 3);
    expect(failure.needsAccountAction, false);
    await f.reopen(0);
    final reopened = f.workspaces.first;
    expect(reopened.processingFailures.single.id, failure.id);
    await reopened.recoverProcessingFailure(failure.id);
    expect(f.modelRequests, hasLength(5));
    expect(reopened.processingFailures, isEmpty);
    expect(reopened.notes, hasLength(1));
    expect(reopened.notes.single.id, note.id);
    expect(reopened.notes.single.text, '整理后的普通想法。');
    expect(reopened.notes.single.originalText, '恢复前的原文。');
  });
  test('credential and balance failures are listed for account action without automatic requests', () async {
    final f = BudgetFixture()..modelStatuses.addAll([401, 402]);
    await f.start();
    addTearDown(f.close);
    final w = f.workspaces.first;
    final note = await w.captureText(title: '凭据失败', text: '凭据错误也保留原文。');
    await w.processTextNote(note.id);
    expect(f.modelRequests, hasLength(1));
    var failure = w.processingFailures.single;
    expect(failure.needsAccountAction, true);
    expect(failure.automaticRetriesUsed, 0);
    expect(failure.recovery, ProcessingRecovery.retry);
    await w.recoverProcessingFailure(failure.id);
    expect(f.modelRequests, hasLength(2));
    failure = w.processingFailures.single;
    expect(failure.needsAccountAction, true);
    expect(failure.message, contains('余额不足'));
    expect(w.notes.single.text, '凭据错误也保留原文。');
  });

  test('an invalid model result is listed and a manual retry applies one valid result', () async {
    final f = BudgetFixture()..malformedContent = true;
    await f.start();
    addTearDown(f.close);
    final w = f.workspaces.first;
    final note = await w.captureText(title: '无效结果', text: '无效结果不覆盖原文。');
    await w.processTextNote(note.id);
    expect(f.modelRequests, hasLength(1));
    final failure = w.processingFailures.single;
    expect(failure.recovery, ProcessingRecovery.retry);
    expect(w.notes.single.text, '无效结果不覆盖原文。');
    f.malformedContent = false;
    await w.recoverProcessingFailure(failure.id);
    expect(f.modelRequests, hasLength(2));
    expect(w.processingFailures, isEmpty);
    expect(w.notes, hasLength(1));
    expect(w.notes.single.text, '整理后的普通想法。');
    expect(w.notes.single.originalText, '无效结果不覆盖原文。');
  });

  test('an audio failure recovers stage by stage without re-uploading a saved transcript', () async {
    // The transcript is paid for; organizing fails once (a 503).
    final f = BudgetFixture()..modelStatuses.add(503);
    await f.start();
    addTearDown(f.close);
    final w = f.workspaces.first;
    final source = await w.importAudio(
      original: await File('${f.root.path}/a.wav').writeAsBytes(wave()),
      submissionId: 'recover-audio',
    );
    await w.prepareAudioProcessing(source.id);
    await w.confirmAudioProcessing(source.id);
    expect(f.audioRequests, 1);
    expect(f.modelRequests, hasLength(1));
    var failure = w.processingFailures.single;
    expect(failure.source, ProcessingFailureSource.audio);
    expect(failure.recovery, ProcessingRecovery.reorganizeOnly);
    await w.recoverProcessingFailure(failure.id);
    failure = w.processingFailures.single;
    expect(failure.recovery, ProcessingRecovery.confirmPrepared);
    expect(failure.estimatedCnyMicros, greaterThan(0));
    expect(f.modelRequests, hasLength(1));
    await f.reopen(0);
    final reopened = f.workspaces.first;
    await reopened.recoverProcessingFailure(failure.id);
    expect(f.audioRequests, 1);
    expect(f.modelRequests, hasLength(2));
    // Organized; only the failed first attempt's fee is unconfirmed, so the
    // offer is to check that cost, never to organize (and pay) again.
    expect(
      reopened.processingFailures.single.recovery,
      ProcessingRecovery.reconcileCost,
    );
    expect(reopened.notes, hasLength(1));
    expect(reopened.notes.single.text, '整理后的普通想法。');
    expect(reopened.notes.single.originalText, f.transcript);
    expect(await File(source.originalPath).readAsBytes(), wave());
  });

  test('a failed document extraction is listed and retried with its retained original', () async {
    final f = BudgetFixture();
    await f.start();
    addTearDown(f.close);
    final w = f.workspaces.first;
    final note = await w.importDocument(
      original: File('test/fixtures/word/body-table.docx'),
      options: const DocumentExtractionOptions(maximumCharacters: 1),
    );
    final failure = w.processingFailures.single;
    expect(failure.source, ProcessingFailureSource.document);
    expect(failure.noteId, note.id);
    expect(failure.recovery, ProcessingRecovery.retry);
    await w.recoverProcessingFailure(failure.id);
    expect(w.processingFailures, isEmpty);
    expect(w.notes, hasLength(1));
    expect(
      w.notes.single.document!.result!.completion,
      DocumentCompletion.complete,
    );
    expect(w.attachments, hasLength(1));
  });

  Future<(BudgetFixture, NoteWorkspace, WorkspaceAudioSource)> processedAudio({
    Map<String, dynamic>? result,
  }) async {
    final f = BudgetFixture()..modelResult = result;
    await f.start();
    addTearDown(f.close);
    final w = f.workspaces.first;
    final source = await w.importAudio(
      original: await File('${f.root.path}/a.wav').writeAsBytes(wave()),
      submissionId: 'processed-audio',
    );
    await w.prepareAudioProcessing(source.id);
    await w.confirmAudioProcessing(source.id);
    expect(w.audioJobs.single.status, AudioJobStatus.completed);
    return (f, w, source);
  }

  test('correcting a transcript in the App keeps the audio and organized body and calls no model', () async {
    final (f, w, source) = await processedAudio();
    final note = w.notes.single;
    final markdown = await File(note.notePath).readAsString();
    final corrected = await w.correctTranscript(note.id, '明天下午三点整理会议记录。');
    expect(corrected.originalText, '明天下午三点整理会议记录。');
    expect(corrected.text, note.text);
    expect(await File(note.sourcePath).readAsString(), '明天下午三点整理会议记录。');
    expect(await File(note.notePath).readAsString(), markdown);
    expect(await File(source.originalPath).readAsBytes(), wave());
    expect(f.audioRequests, 1);
    expect(f.modelRequests, hasLength(1));
    await f.reopen(0);
    final reopened = f.workspaces.first;
    expect(reopened.notes.single.originalText, '明天下午三点整理会议记录。');
    expect(
      await File(reopened.notes.single.sourcePath).readAsString(),
      '明天下午三点整理会议记录。',
    );
  });

  test(
    'a transcript edited elsewhere is never overwritten by an App correction',
    () async {
      final (_, w, _) = await processedAudio();
      final note = w.notes.single;
      await File(note.sourcePath).writeAsString('在 Obsidian 中修改的转写。');
      await expectLater(
        w.correctTranscript(note.id, 'App 内更正。'),
        throwsA(isA<StateError>()),
      );
      expect(await File(note.sourcePath).readAsString(), '在 Obsidian 中修改的转写。');
      expect(w.notes.single.originalText, isNot('App 内更正。'));
    },
  );

  Map<String, dynamic> todoAt(String time) => {
    'kind': 'todo',
    'title': '整理会议记录',
    'body': '整理会议记录。',
    'actions': [
      {
        'text': '整理会议记录',
        'reason': 'none',
        'timeExpression': time,
        'timeStatus': 'explicit',
      },
    ],
  };

  test('a corrected transcript is reorganized as a preview and applied once without duplicate reminders', () async {
    final (f, w, source) = await processedAudio(result: todoAt('明天下午两点'));
    final note = w.notes.single;
    final firstReminder = w.reminders.single;
    await w.correctTranscript(note.id, '明天下午三点整理会议记录。');
    final job = await w.prepareReorganization(note.id);
    expect(job.status, TextProcessingStatus.prepared);
    expect(job.estimatedCnyMicros, greaterThan(0));
    expect(f.modelRequests, hasLength(1));
    f.modelResult = {...todoAt('明天下午三点'), 'body': '下午三点整理会议记录。'};
    final preview = await w.previewReorganization(job.id);
    expect(f.modelRequests, hasLength(2));
    final input = jsonDecode(
      f.modelRequests.last['messages'].last['content'] as String,
    ) as Map;
    expect(input['text'], '明天下午三点整理会议记录。');
    expect(preview.body, '下午三点整理会议记录。');
    expect(preview.kind, NoteKind.todo);
    expect(preview.actions.single.timeExpression, '明天下午三点');
    expect(preview.stale, false);
    expect(w.notes.single.text, note.text);
    expect(w.reminders.single.id, firstReminder.id);
    expect(w.reorganizationPreviews.single.jobId, job.id);
    await f.reopen(0);
    final reopened = f.workspaces.first;
    expect(reopened.notes.single.text, note.text);
    expect(reopened.reorganizationPreviews.single.body, '下午三点整理会议记录。');
    final applied = await reopened.applyReorganization(job.id);
    expect(applied.text, '下午三点整理会议记录。');
    expect(applied.originalText, '明天下午三点整理会议记录。');
    expect(reopened.reorganizationPreviews, isEmpty);
    final collected = applied.createdAt.toLocal();
    expect(
      reopened.reminders.single.time,
      DateTime(collected.year, collected.month, collected.day + 1, 15),
    );
    await f.reopen(0);
    expect(f.workspaces.first.notes, hasLength(1));
    expect(f.workspaces.first.reminders, hasLength(1));
    expect(f.audioRequests, 1);
    expect(f.modelRequests, hasLength(2));
    expect(await File(source.originalPath).readAsBytes(), wave());
  });

  test('re-organizing removes the old actions on paired devices too', () async {
    final (f, w, _) = await processedAudio(result: todoAt('明天下午两点'));
    final note = w.notes.single;
    final old = note.actions.single.id;
    await w.completeAction(note.id, old);
    expect(await w.syncTodos(), TaskStatusSync.synced);
    final other = f.workspaces[1];
    expect(await other.syncTodos(), TaskStatusSync.synced);
    expect(other.todoSync.awaitingNote.map((a) => a.actionId), [old]);

    await w.correctTranscript(note.id, '明天下午三点整理会议记录。');
    f.modelResult = todoAt('明天下午三点');
    final job = await w.prepareReorganization(note.id);
    await w.previewReorganization(job.id);
    final applied = await w.applyReorganization(job.id);
    expect(applied.actions.single.id, isNot(old));
    expect(await w.syncTodos(), TaskStatusSync.synced);
    expect(await other.syncTodos(), TaskStatusSync.synced);
    expect(
      other.todoSync.awaitingNote.map((a) => a.actionId),
      isNot(contains(old)),
    );
  });

  test('a note changed after its preview keeps the newer content and the preview is only discarded', () async {
    final (f, w, _) = await processedAudio(result: todoAt('明天下午两点'));
    final note = w.notes.single;
    final job = await w.prepareReorganization(note.id);
    final preview = await w.previewReorganization(job.id);
    expect(preview.stale, false);
    await w.resolveNoteActions(note.id, kind: NoteKind.ordinary, actions: []);
    final edited = w.notes.single;
    expect(edited.kind, NoteKind.ordinary);
    expect(w.reminders, isEmpty);
    expect(w.reorganizationPreviews.single.stale, true);
    await expectLater(
      w.applyReorganization(job.id),
      throwsA(isA<StateError>()),
    );
    expect(w.notes.single.kind, NoteKind.ordinary);
    expect(w.notes.single.text, edited.text);
    expect(w.reminders, isEmpty);
    await w.discardReorganization(job.id);
    expect(w.reorganizationPreviews, isEmpty);
    expect(w.processingFailures, isEmpty);
    expect(f.modelRequests, hasLength(2));
  });

  test('an Obsidian edit read after a preview makes it stale, and an applied preview is not read back as an edit', () async {
    final (f, w, _) = await processedAudio(result: todoAt('明天下午两点'));
    final note = w.notes.single;
    final job = await w.prepareReorganization(note.id);
    await w.previewReorganization(job.id);
    final file = File(note.notePath);
    final text = await file.readAsString();
    expect(text, contains(note.text));
    await file.writeAsString(text.replaceFirst(note.text, '在 Obsidian 里改过'));
    await file.setLastModified(DateTime.now().add(const Duration(minutes: 5)));
    expect(await w.readVaultEdits(), [note.id]);
    expect(w.notes.single.text, '在 Obsidian 里改过');
    expect(w.reorganizationPreviews.single.stale, true);
    await expectLater(
      w.applyReorganization(job.id),
      throwsA(isA<StateError>()),
    );
    expect(w.notes.single.text, '在 Obsidian 里改过');
    await w.discardReorganization(job.id);

    final again = await w.prepareReorganization(note.id);
    f.modelResult = {...todoAt('明天下午两点'), 'body': '重新整理后的正文。'};
    await w.previewReorganization(again.id);
    final applied = await w.applyReorganization(again.id);
    expect(applied.text, '重新整理后的正文。');
    expect(await w.readVaultEdits(), isEmpty);
    expect(w.notes.single.text, '重新整理后的正文。');
    expect(w.reminders, hasLength(1));
  });

  test('a preview of a note moved to the recycle bin is hidden until the note is restored', () async {
    final (_, w, _) = await processedAudio(result: todoAt('明天下午两点'));
    final note = w.notes.single;
    final job = await w.prepareReorganization(note.id);
    await w.previewReorganization(job.id);
    await w.deleteNote(note.id);
    expect(w.reorganizationPreviews, isEmpty);
    await expectLater(
      w.applyReorganization(job.id),
      throwsA(isA<StateError>()),
    );
    await w.restoreNote(note.id);
    expect(w.reorganizationPreviews.single.jobId, job.id);
  });

  test('duplicate recovery and preview requests send once and never duplicate notes', () async {
    final f = BudgetFixture()..modelStatuses.addAll([401]);
    await f.start();
    addTearDown(f.close);
    final w = f.workspaces.first;
    final note = await w.captureText(title: '重复点击', text: '重复点击只发送一次。');
    await w.processTextNote(note.id);
    final failure = w.processingFailures.single;
    await Future.wait([
      w.recoverProcessingFailure(failure.id),
      w.recoverProcessingFailure(failure.id),
    ]);
    expect(f.modelRequests, hasLength(2));
    expect(w.notes, hasLength(1));
    final job = await w.prepareReorganization(note.id);
    await expectLater(
      w.prepareReorganization(note.id),
      throwsA(isA<StateError>()),
    );
    final previews = await Future.wait([
      w.previewReorganization(job.id),
      w.previewReorganization(job.id),
    ]);
    expect(previews.map((p) => p.jobId).toSet(), {job.id});
    expect(f.modelRequests, hasLength(3));
    await w.applyReorganization(job.id);
    await expectLater(
      w.applyReorganization(job.id),
      throwsA(isA<StateError>()),
    );
    expect(w.notes, hasLength(1));
    expect(w.processingFailures, isEmpty);
  });
}
