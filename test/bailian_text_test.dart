import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:note_agent/note_workspace.dart';

import 'support/budget_fixture.dart';

/// A quote as the app saved it before the switch to Bailian.
Map<String, Object?> openRouterQuote(Map current) => {
  'id': current['id'],
  'model': 'deepseek/deepseek-v4.1-flash',
  'provider': 'fixture/provider',
  'promptNano': 600,
  'completionNano': 2400,
  'fxMicros': 7700000,
  'fxDate': '2026-10-20',
  'expiresAt': current['expiresAt'],
};

/// Text organizing through Bailian (ADR 0003) against the local Worker with a
/// yuan price table (800 / 2000 nano-元 per input / output token).
void main() {
  test(
    'a note is organized by qwen-plus and settled in yuan from its token usage',
    () async {
      final f = BudgetFixture();
      await f.start();
      addTearDown(f.close);
      final w = f.workspaces.first;
      final note = await w.captureText(title: '想法', text: '今天读完了一本关于习惯的书。');
      final job = await w.prepareTextProcessing(note.id);
      expect(job.status, TextProcessingStatus.prepared);
      expect(job.quoteDescription, contains('qwen-plus'));
      expect(job.quoteDescription, contains('¥0.8/百万 token'));
      expect(f.modelRequests, isEmpty);

      final done = await w.processTextNote(note.id);
      expect(done.status, TextProcessingStatus.completed, reason: done.message);
      final request = f.modelRequests.single;
      expect(request['model'], 'qwen-plus');
      expect(request['enable_thinking'], isFalse);
      expect((request['response_format'] as Map)['type'], 'json_schema');
      expect(request.containsKey('provider'), isFalse);
      expect(request.containsKey('reasoning'), isFalse);

      await w.refreshBudget();
      // 37 × 800 + 22 × 2000 = 73600 nano-元 → 74 micro-元.
      expect(w.budget.spentCnyMicros, 74);
      expect(w.budget.reservedCnyMicros, 0);
      expect(w.textJobs.single.knownCostCnyMicros, 74);
    },
  );

  test('a response without usage keeps its hold across restart and is never looked up', () async {
    final f = BudgetFixture();
    await f.start();
    addTearDown(f.close);
    f.omitCost = true;
    final w = f.workspaces.first;
    final note = await w.captureText(title: '想法', text: '明天十点给物业打电话。');
    final job = await w.prepareTextProcessing(note.id);
    final sent = await w.processTextNote(note.id);
    expect(sent.status, TextProcessingStatus.costPending);
    await w.refreshBudget();
    final held = w.budget.reservedCnyMicros;
    expect(held, greaterThan(0));

    await f.reopen(0);
    final again = f.workspaces.first;
    final recovered = await again.reconcileTextProcessing(job.id);
    expect(recovered.status, TextProcessingStatus.costPending);
    expect(recovered.message, contains('阿里云百炼控制台'));
    await again.refreshBudget();
    expect(again.budget.reservedCnyMicros, held);
    expect(f.generationReads, 0);
  });

  test('a job estimated before the switch is released for a new estimate, never sent', () async {
    final f = BudgetFixture();
    await f.start();
    addTearDown(f.close);
    final note = await f.workspaces.first.captureText(
      title: '切换前',
      text: '切换前预估、尚未发送的想法。',
    );
    final job = await f.workspaces.first.prepareTextProcessing(note.id);
    expect(job.status, TextProcessingStatus.prepared);
    await f.reopen(
      0,
      whileClosed: (local) {
        // Stand in for the old app's saved job: an OpenRouter quote and request.
        final db = sqlite3.open('${local.path}/workspace.sqlite3');
        final row = db.select('SELECT payload FROM text_jobs WHERE id=?', [
          job.id,
        ]);
        final payload = jsonDecode(row.single['payload'] as String) as Map;
        payload['quote'] = openRouterQuote(payload['quote'] as Map);
        (payload['request'] as Map)['model'] = 'deepseek/deepseek-v4.1-flash';
        db.execute('UPDATE text_jobs SET payload=? WHERE id=?', [
          jsonEncode(payload),
          job.id,
        ]);
        db.close();
      },
    );

    final w = f.workspaces.first;
    final result = await w.processTextNote(note.id);
    expect(f.modelRequests, isEmpty);
    expect(result.id, job.id);
    expect(result.status, TextProcessingStatus.cancelled);
    expect(result.message, contains('重新预估'));
    await w.refreshBudget();
    expect(w.budget.reservedCnyMicros, 0);
    expect(File(note.sourcePath).existsSync(), isTrue);
  });

  test(
    'a job settled before the switch stays settled when reconciled',
    () async {
      final f = BudgetFixture();
      await f.start();
      addTearDown(f.close);
      final note = await f.workspaces.first.captureText(
        title: '切换前已结算',
        text: '切换前已整理并结清的想法。',
      );
      final done = await f.workspaces.first.processTextNote(note.id);
      expect(done.status, TextProcessingStatus.completed);
      await f.reopen(
        0,
        whileClosed: (local) {
          // The old app's receipt: an OpenRouter generation id and USD cost.
          final db = sqlite3.open('${local.path}/workspace.sqlite3');
          final row = db.select('SELECT payload FROM text_jobs WHERE id=?', [
            done.id,
          ]);
          final payload = jsonDecode(row.single['payload'] as String) as Map;
          for (final receipt in (payload['receipts'] as Map).values) {
            (receipt as Map)
              ..remove('settle')
              ..remove('cnyMicros')
              ..['usdNanos'] = 10000;
          }
          payload['quote'] = openRouterQuote(payload['quote'] as Map);
          db.execute('UPDATE text_jobs SET payload=? WHERE id=?', [
            jsonEncode(payload),
            done.id,
          ]);
          db.close();
        },
      );
      final w = f.workspaces.first;
      final reconciled = await w.reconcileTextProcessing(done.id);
      expect(
        reconciled.status,
        TextProcessingStatus.completed,
        reason: reconciled.message,
      );
      await w.refreshBudget();
      expect(w.budget.reservedCnyMicros, 0);
      expect(f.modelRequests.length, 1);
    },
  );

  test('a lost response is listed, and the charge checked in the console settles it', () async {
    final f = BudgetFixture()..omitCost = true;
    await f.start();
    addTearDown(f.close);
    final w = f.workspaces.first;
    final note = await w.captureText(title: '想法', text: '明天十点给物业打电话。');
    final job = await w.processTextNote(note.id);
    expect(job.status, TextProcessingStatus.costPending);
    // Organized, so not a processing failure: the job is the key.
    expect(w.processingFailures, isEmpty);
    final key = 'text:${job.id}';
    final charges = await w.unconfirmedCharges(key);
    expect(charges, hasLength(1));
    expect(charges.single.heldCnyMicros, greaterThan(0));
    expect(charges.single.label, contains('整理'));

    await w.recordConfirmedCharge(key, charges.single.attemptId, 650);
    await w.refreshBudget();
    expect(w.budget.reservedCnyMicros, 0);
    expect(w.budget.spentCnyMicros, 650);
    expect(w.textJobs.single.knownCostCnyMicros, 650);
    expect(await w.unconfirmedCharges(key), isEmpty);
    expect(f.modelRequests, hasLength(1));
  });

  test(
    'a confirmed charge whose reply was lost is taken from the ledger',
    () async {
      final f = BudgetFixture()..omitCost = true;
      await f.start();
      addTearDown(f.close);
      final w = f.workspaces.first;
      final note = await w.captureText(title: '想法', text: '明天十点给物业打电话。');
      final job = await w.processTextNote(note.id);
      final key = 'text:${job.id}';
      final attempt = (await w.unconfirmedCharges(key)).single.attemptId;
      f.loseBudgetReply = (path) => path.endsWith('/settle');
      await expectLater(
        w.recordConfirmedCharge(key, attempt, 650),
        throwsA(anything),
      );
      f.loseBudgetReply = null;

      // The Worker settled it: the job adopts that amount, nothing is left.
      expect(await w.unconfirmedCharges(key), isEmpty);
      await w.reconcileTextProcessing(job.id);
      expect(w.textJobs.single.knownCostCnyMicros, 650);
      await w.refreshBudget();
      expect(w.budget.reservedCnyMicros, 0);
      expect(w.budget.spentCnyMicros, 650);
    },
  );
}
