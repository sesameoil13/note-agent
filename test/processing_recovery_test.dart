import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/note_workspace.dart';

import 'support/budget_fixture.dart';
import 'audio_queue_test.dart' show wave;
import 'support/organize_now.dart';

void main() {
  // Automatic retries of a capture come with the retry schedule (#40).
  test(
    'a text failure is listed once and recovers manually into the same note',
    () async {
      final f = BudgetFixture()..modelStatuses.add(503);
      await f.start();
      addTearDown(f.close);
      final w = f.workspaces.first;
      final note = await w.captureText(title: '失败恢复', text: '恢复前的原文。');
      await w.organizeNow(note.id);
      expect(f.modelRequests, hasLength(1));
      expect(w.organizeStatus(note.id), OrganizeStatus.failed);
      final failure = w.processingFailures.single;
      expect(failure.source, ProcessingFailureSource.text);
      expect(failure.noteId, note.id);
      expect(failure.title, '失败恢复');
      expect(failure.recovery, ProcessingRecovery.retry);
      expect(failure.automaticRetriesUsed, 0);
      expect(failure.needsAccountAction, false);
      await f.reopen(0);
      final reopened = f.workspaces.first;
      expect(reopened.processingFailures.single.id, failure.id);
      await reopened.recoverProcessingFailure(failure.id);
      expect(f.modelRequests, hasLength(2));
      expect(reopened.processingFailures, isEmpty);
      expect(reopened.notes, hasLength(1));
      expect(reopened.notes.single.id, note.id);
      expect(reopened.notes.single.text, '整理后的普通想法。');
      expect(reopened.notes.single.originalText, '恢复前的原文。');
    },
  );
  test('credential and balance failures are listed for account action without automatic requests', () async {
    final f = BudgetFixture()..modelStatuses.addAll([401, 402]);
    await f.start();
    addTearDown(f.close);
    final w = f.workspaces.first;
    final note = await w.captureText(title: '凭据失败', text: '凭据错误也保留原文。');
    await w.organizeNow(note.id);
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
    await w.organizeNow(note.id);
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
    await w.sendWaitingNow();
    expect(w.organizeStatus(source.outputNoteId), OrganizeStatus.organized);
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

  test(
    'duplicate recovery requests send once and never duplicate notes',
    () async {
      final f = BudgetFixture()..modelStatuses.addAll([401]);
      await f.start();
      addTearDown(f.close);
      final w = f.workspaces.first;
      final note = await w.captureText(title: '重复点击', text: '重复点击只发送一次。');
      await w.organizeNow(note.id);
      final failure = w.processingFailures.single;
      await Future.wait([
        w.recoverProcessingFailure(failure.id),
        w.recoverProcessingFailure(failure.id),
      ]);
      expect(f.modelRequests, hasLength(2));
      expect(w.notes, hasLength(1));
      expect(w.processingFailures, isEmpty);
    },
  );
}
