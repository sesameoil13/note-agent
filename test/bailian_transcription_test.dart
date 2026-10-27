import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/note_workspace.dart';

import 'support/budget_fixture.dart';
import 'audio_queue_test.dart' show wave;

/// Transcription through Bailian (ADR 0003) against the local Worker: one
/// budget attempt per part, priced at 250000 nano-元 per second (fixture).
void main() {
  Future<WorkspaceAudioSource> importWave(
    BudgetFixture f,
    int seconds,
    String id,
  ) async => f.workspaces.first.importAudio(
    original: await File('${f.root.path}/$id.wav')
        .writeAsBytes(wave(seconds: seconds)),
    submissionId: id,
  );

  test(
    'a short recording is one qwen3-asr-flash request, settled by its seconds',
    () async {
      final f = BudgetFixture();
      await f.start();
      addTearDown(f.close);
      final w = f.workspaces.first;
      final source = await importWave(f, 4, 'short');
      final prepared = await w.prepareAudioProcessing(source.id);
      expect(prepared.status, AudioJobStatus.prepared);
      expect(prepared.description, contains('qwen3-asr-flash'));
      await w.confirmAudioProcessing(source.id);

      expect(f.audioRequests, 1);
      final request = f.lastAudioRequest!;
      expect(request['model'], 'qwen3-asr-flash');
      final content = ((request['messages'] as List).single as Map)['content'];
      final audio = ((content as List).single as Map)['input_audio'] as Map;
      expect(audio['data'], startsWith('data:audio/wav;base64,'));
      expect(
        base64Decode((audio['data'] as String).split(',').last),
        wave(seconds: 4),
      );
      expect((request['asr_options'] as Map)['enable_itn'], isFalse);
      expect(w.notes.single.originalText, f.transcript);
      await w.refreshBudget();
      // 4 s × 250000 nano-元 = 1000 micro-元, plus the organizing stage.
      expect(w.budget.reservedCnyMicros, 0);
      expect(w.budget.spentCnyMicros, 1000 + 74);
    },
  );

  test(
    'a six-minute recording is sent as two parts in order and joined',
    () async {
      final f = BudgetFixture()..partTranscripts = ['第一段内容。', '第二段内容。'];
      await f.start();
      addTearDown(f.close);
      final w = f.workspaces.first;
      final source = await importWave(f, 360, 'long');
      final prepared = await w.prepareAudioProcessing(source.id);
      expect(
        prepared.status,
        AudioJobStatus.prepared,
        reason: prepared.message,
      );
      expect(prepared.description, contains('分 2 段'));
      await w.confirmAudioProcessing(source.id);

      expect(f.audioRequests, 2);
      expect(f.audioSeconds, [180, 180]);
      expect(w.notes.single.originalText, '第一段内容。第二段内容。');
      await w.refreshBudget();
      expect(w.budget.reservedCnyMicros, 0);
      // 2 × 180 s × 250000 nano-元 = 90000 micro-元, plus organizing.
      expect(w.budget.spentCnyMicros, 90000 + 74);
    },
  );

  test(
    'a failed second part keeps the first, and a retry sends only the second',
    () async {
      final f = BudgetFixture()
        ..partTranscripts = ['第一段内容。', '第二段内容。', '第二段内容。']
        ..audioStatuses.addAll([200, 503]);
      await f.start();
      addTearDown(f.close);
      final w = f.workspaces.first;
      final source = await importWave(f, 360, 'retry');
      await w.prepareAudioProcessing(source.id);
      final failed = await w.confirmAudioProcessing(source.id);
      expect(failed.status, AudioJobStatus.paused);
      expect(f.audioRequests, 2);
      expect(f.modelRequests, isEmpty);
      // The first part is settled; the failed second keeps an unknown hold.
      await w.refreshBudget();
      expect(w.budget.spentCnyMicros, 45000);
      final unknown = w.budget.unknownCnyMicros;
      expect(unknown, greaterThan(0));

      await f.reopen(0);
      final again = f.workspaces.first;
      final retry = await again.prepareAudioRetry(source.id);
      expect(retry.status, AudioJobStatus.prepared, reason: retry.message);
      await again.confirmAudioProcessing(source.id);
      expect(f.audioRequests, 3);
      expect(f.audioSeconds.last, 180);
      expect(again.notes.single.originalText, '第一段内容。第二段内容。');
      await again.refreshBudget();
      expect(again.budget.unknownCnyMicros, unknown);
    },
  );

  test(
    'a part without usage stays held and is checked in the console',
    () async {
      final f = BudgetFixture()..omitAudioCost = true;
      await f.start();
      addTearDown(f.close);
      final w = f.workspaces.first;
      final source = await importWave(f, 4, 'no-usage');
      await w.prepareAudioProcessing(source.id);
      final job = await w.confirmAudioProcessing(source.id);
      expect(job.status, AudioJobStatus.paused);
      expect(job.transcript, f.transcript);
      expect(f.modelRequests, isEmpty);
      final reconciled = await w.reconcileAudioProcessing(source.id);
      expect(reconciled.message, contains('阿里云百炼控制台'));
      await w.refreshBudget();
      expect(w.budget.reservedCnyMicros, greaterThan(0));
      expect(f.generationReads, 0);
    },
  );

  test(
    'a transcript that arrives is published even if settling its cost fails',
    () async {
      final f = BudgetFixture();
      await f.start();
      addTearDown(f.close);
      final w = f.workspaces.first;
      final source = await importWave(f, 4, 'settle-fails');
      await w.prepareAudioProcessing(source.id);
      f.failBudgetRequest = (path) => path.endsWith('/settle');
      final job = await w.confirmAudioProcessing(source.id);
      expect(job.status, AudioJobStatus.paused);
      expect(job.transcript, f.transcript);
      expect(w.notes.single.originalText, f.transcript);
      expect(
        w.processingFailures.single.recovery,
        ProcessingRecovery.reconcileCost,
      );

      f.failBudgetRequest = null;
      await w.reconcileAudioProcessing(source.id);
      await w.refreshBudget();
      expect(w.budget.spentCnyMicros, 1000);
      expect(f.audioRequests, 1);
    },
  );

  test(
    'cancelling a retry estimate and estimating again keeps the paid parts',
    () async {
      final f = BudgetFixture()
        ..partTranscripts = ['第一段内容。', '第二段内容。', '第二段内容。']
        ..audioStatuses.addAll([200, 503]);
      await f.start();
      addTearDown(f.close);
      final w = f.workspaces.first;
      final source = await importWave(f, 360, 'cancel-retry');
      await w.prepareAudioProcessing(source.id);
      await w.confirmAudioProcessing(source.id);
      expect(f.audioRequests, 2);
      await w.prepareAudioRetry(source.id);
      await w.cancelAudioProcessing(source.id);
      final again = await w.prepareAudioProcessing(source.id);
      expect(again.status, AudioJobStatus.prepared, reason: again.message);
      await w.confirmAudioProcessing(source.id);
      // Only the second part is sent again; the first stays paid once.
      expect(f.audioRequests, 3);
      expect(w.notes.single.originalText, '第一段内容。第二段内容。');
    },
  );

  test('a part without a receipt is settled from the console, then organizing can go on', () async {
    final f = BudgetFixture()..omitAudioCost = true;
    await f.start();
    addTearDown(f.close);
    final w = f.workspaces.first;
    final source = await importWave(f, 4, 'confirm-part');
    await w.prepareAudioProcessing(source.id);
    await w.confirmAudioProcessing(source.id);
    final failure = w.processingFailures.single;
    expect(failure.recovery, ProcessingRecovery.reconcileCost);
    final charges = await w.unconfirmedCharges(failure.id);
    expect(charges.map((c) => c.label), ['转写']);

    await w.recordConfirmedCharge(failure.id, charges.single.attemptId, 1000);
    await w.refreshBudget();
    expect(w.budget.spentCnyMicros, 1000);
    expect(w.budget.reservedCnyMicros, 0);
    expect(
      w.processingFailures.single.recovery,
      ProcessingRecovery.reorganizeOnly,
    );
    expect(await w.unconfirmedCharges(failure.id), isEmpty);
    expect(f.audioRequests, 1);
  });
}
