import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/note_workspace.dart';

import 'support/budget_fixture.dart';

void main() {
  test('disconnected budget does not block a locally saved original across restart', () async {
    final root = await Directory.systemTemp.createTemp('budget-local-');
    final vault = await Directory('${root.path}/vault').create();
    final local = Directory('${root.path}/local');
    var workspace = await NoteWorkspace.open(
      localDirectory: local,
      vaultDirectory: vault,
    );
    final note = await workspace.captureText(
      title: '离线想法',
      text: '先保存原文，连接后再整理。',
    );
    expect(workspace.budget.connected, isFalse);
    expect(workspace.budget.paused, isTrue);
    expect(workspace.budget.prepaidBalanceUsdMicros, isNull);
    expect(await File(note.sourcePath).readAsString(), contains('先保存原文'));
    await workspace.close();
    workspace = await NoteWorkspace.open(
      localDirectory: local,
      vaultDirectory: vault,
    );
    expect(workspace.notes.single.originalText, '先保存原文，连接后再整理。');
    expect(workspace.budget.message, contains('本机保存'));
    await workspace.close();
    await root.delete(recursive: true);
  });
  test(
    'three paired devices cannot each reserve the same shared remaining funds',
    () async {
      final f = BudgetFixture();
      await f.start();
      addTearDown(f.close);
      await f.workspaces.first.setMonthlyBudgetLimit(100000);
      final notes = await Future.wait([
        for (final w in f.workspaces)
          w.captureText(
            title: '预算并发',
            text: '普通想法${List.filled(400, '内容').join()}',
          ),
      ]);
      final jobs = await Future.wait([
        for (var i = 0; i < 3; i++)
          f.workspaces[i].prepareTextProcessing(notes[i].id),
      ]);
      expect(
        jobs.where((j) => j.status == TextProcessingStatus.prepared).length,
        2,
        reason: jobs.map((j) => j.message).join(" | "),
      );
      await f.workspaces.last.refreshBudget();
      expect(f.workspaces.last.budget.reservedCnyMicros, greaterThan(0));
      expect(f.workspaces.last.budget.remainingCnyMicros, lessThan(50000));
      expect(f.workspaces.last.budget.prepaidBalanceUsdMicros, isNull);
      expect(f.workspaces.every((w) => w.notes.length == 1), isTrue);
    },
  );

  test(
    'duplicate prepare actions reserve once and the same job survives restart',
    () async {
      final f = BudgetFixture();
      await f.start();
      addTearDown(f.close);
      final w = f.workspaces.first;
      final note = await w.captureText(title: '一次收集', text: '一条普通记录。');
      final jobs = await Future.wait([
        w.prepareTextProcessing(note.id),
        w.prepareTextProcessing(note.id),
      ]);
      expect(jobs.map((j) => j.id).toSet().length, 1);
      final held = w.budget.reservedCnyMicros;
      await f.reopen(0);
      final restored = await f.workspaces.first.prepareTextProcessing(note.id);
      expect(restored.id, jobs.first.id);
      await f.workspaces.first.refreshBudget();
      expect(f.workspaces.first.budget.reservedCnyMicros, held);
      expect(f.workspaces.first.textJobs.length, 1);
    },
  );
  test('budgeted exact-model completion updates one ordinary note and preserves its original across restart', () async {
    final f = BudgetFixture();
    await f.start();
    addTearDown(f.close);
    final w = f.workspaces.first;
    final note = await w.captureText(title: '原始记录', text: '原文：给自己留一段普通想法。');
    final source = await File(note.sourcePath).readAsBytes();
    final job = await w.processTextNote(note.id);
    expect(job.status, TextProcessingStatus.completed);
    expect(job.generationIds, ['gen-budget-fixture-1']);
    expect(job.knownCostUsdNanos, 10000);
    expect(job.inputTokens, 37);
    expect(job.outputTokens, 22);
    expect(f.modelRequests.single['model'], 'deepseek/deepseek-v4.1-flash');
    expect(f.modelRequests.single['max_tokens'], 1024);
    expect(
      (f.modelRequests.single['provider'] as Map)['allow_fallbacks'],
      isFalse,
    );
    final result = w.notes.single;
    expect(result.id, note.id);
    expect(result.title, '记录想法');
    expect(result.text, '整理后的普通想法。');
    final markdown = await File(result.notePath).readAsString();
    expect(markdown, contains('## 正文'));
    expect(markdown, contains('## 来源'));
    expect(markdown, isNot(contains('## 摘要')));
    expect(await File(note.sourcePath).readAsBytes(), source);
    expect(w.budget.spentCnyMicros, greaterThan(0));
    expect(w.budget.reservedCnyMicros, 0);
    await f.reopen(0);
    expect(f.workspaces.first.notes.single.originalText, '原文：给自己留一段普通想法。');
    expect((await f.workspaces.first.processTextNote(note.id)).id, job.id);
    expect(f.modelRequests.length, 1);
  });
  test('a missing cost keeps its hold across restart and delayed receipt settles once without another model call', () async {
    final f = BudgetFixture()..omitCost = true;
    await f.start();
    addTearDown(f.close);
    final note = await f.workspaces.first.captureText(
      title: '账单待核对',
      text: '普通想法原文。',
    );
    final job = await f.workspaces.first.processTextNote(note.id);
    expect(job.status, TextProcessingStatus.costPending);
    await f.workspaces.first.refreshBudget();
    final held = f.workspaces.first.budget.reservedCnyMicros;
    expect(held, greaterThan(0));
    await f.reopen(0);
    await f.workspaces.first.reconcileTextProcessing(job.id);
    expect(f.workspaces.first.budget.reservedCnyMicros, held);
    expect(f.workspaces.first.budget.spentCnyMicros, 0);
    f.generationAvailable = true;
    await f.workspaces.first.reconcileTextProcessing(job.id);
    expect(f.workspaces.first.budget.reservedCnyMicros, 0);
    expect(f.workspaces.first.budget.spentCnyMicros, 154);
    await f.workspaces.first.reconcileTextProcessing(job.id);
    expect(f.workspaces.first.budget.spentCnyMicros, 154);
    expect(f.modelRequests.length, 1);
    expect(f.workspaces.first.notes.length, 1);
  });
  test('recoverable failures use at most four separately reserved attempts and retain unknown charges', () async {
    final f = BudgetFixture()..modelStatuses.addAll([503, 503, 503, 503, 200]);
    await f.start();
    addTearDown(f.close);
    final w = f.workspaces.first;
    final note = await w.captureText(title: '有限重试', text: '原文不会因重试而丢失。');
    final job = await w.processTextNote(note.id);
    expect(f.modelRequests.length, 4);
    expect(job.attemptCount, 4);
    expect(job.status, TextProcessingStatus.costPending);
    expect(w.budget.unknownCnyMicros, greaterThan(0));
    expect(w.notes.single.text, note.text);
    await f.reopen(0);
    await f.workspaces.first.processTextNote(note.id);
    expect(f.modelRequests.length, 4);
  });
  test('authentication rejection does not retry and malformed paid content is retained for review', () async {
    final f = BudgetFixture()..modelStatuses.add(401);
    await f.start();
    addTearDown(f.close);
    final w = f.workspaces.first;
    final n = await w.captureText(title: '错误原文', text: '仍需保留。');
    await w.processTextNote(n.id);
    expect(f.modelRequests.length, 1);
    f.malformedContent = true;
    final n2 = await w.captureText(title: '格式原文', text: '格式错误也不覆盖。');
    final j = await w.processTextNote(n2.id);
    expect(j.status, TextProcessingStatus.review);
    expect(w.notes.firstWhere((n) => n.id == n2.id).text, n2.text);
    expect(w.budget.spentCnyMicros, greaterThan(0));
    expect(f.modelRequests.length, 2);
  });
  test('new month excludes previous settled spending but retains every unknown hold', () async {
    final f = BudgetFixture();
    await f.start();
    addTearDown(f.close);
    final w = f.workspaces.first;
    final paid = await w.captureText(title: '已结算', text: '普通已结算想法。');
    await w.processTextNote(paid.id);
    f.omitCost = true;
    final pending = await w.captureText(title: '待核对', text: '普通未结算想法。');
    await w.processTextNote(pending.id);
    final hold = w.budget.reservedCnyMicros;
    expect(w.budget.spentCnyMicros, greaterThan(0));
    final now = DateTime.now().toUtc();
    await f.advanceTo(DateTime.utc(now.year, now.month + 1, 2));
    await w.refreshBudget();
    expect(w.budget.spentCnyMicros, 0);
    expect(w.budget.reservedCnyMicros, hold);
    expect(w.budget.unknownCnyMicros, hold);
  });
  test('a conflicting final receipt pauses new paid admission and never overwrites the settled total', () async {
    final f = BudgetFixture();
    await f.start();
    addTearDown(f.close);
    final w = f.workspaces.first;
    final note = await w.captureText(title: '账单冲突', text: '原文仍保留。');
    final job = await w.processTextNote(note.id);
    final cost = w.budget.spentCnyMicros;
    f.generationAvailable = true;
    await w.reconcileTextProcessing(job.id);
    expect(w.budget.paused, isTrue);
    expect(w.budget.spentCnyMicros, cost);
    final next = await w.captureText(title: '冲突后收集', text: '本机继续收集。');
    final pending = await w.prepareTextProcessing(next.id);
    expect(pending.status, TextProcessingStatus.failed);
    expect(f.modelRequests.length, 1);
    expect(w.notes.length, 2);
  });
  test('cancelling an unsent prepared job releases only its own hold and preserves every original', () async {
    final f = BudgetFixture();
    await f.start();
    addTearDown(f.close);
    final w = f.workspaces.first;
    final first = await w.captureText(title: '不发送', text: '先保存，取消只影响任务。');
    final second = await w.captureText(title: '仍预留', text: '另一条仍需保留预留。');
    final a = await w.prepareTextProcessing(first.id);
    await w.prepareTextProcessing(second.id);
    final total = w.budget.reservedCnyMicros;
    final cancelled = await w.cancelTextProcessing(a.id);
    expect(cancelled.status, TextProcessingStatus.cancelled);
    expect(w.budget.reservedCnyMicros, greaterThan(0));
    expect(w.budget.reservedCnyMicros, lessThan(total));
    expect(f.modelRequests, isEmpty);
    await f.reopen(0);
    expect(f.workspaces.first.notes.length, 2);
    expect(
      f.workspaces.first.notes.firstWhere((n) => n.id == first.id).originalText,
      first.text,
    );
  });
  test(
    'a human file edit during a paid request is never overwritten',
    () async {
      final f = BudgetFixture();
      await f.start();
      addTearDown(f.close);
      final w = f.workspaces.first;
      final note = await w.captureText(title: '人类编辑', text: '收集时原文。');
      final edited = '${await File(note.notePath).readAsString()}\n人类后来补充。\n';
      f.beforeReply = () => File(note.notePath).writeAsString(edited);
      final job = await w.processTextNote(note.id);
      expect(job.status, TextProcessingStatus.review);
      expect(await File(note.notePath).readAsString(), edited);
      expect(await File(note.sourcePath).readAsString(), contains(note.text));
      expect(w.budget.spentCnyMicros, greaterThan(0));
    },
  );
  test('manual retry after the automatic limit uses the same note and fresh funds while all older unknown holds remain', () async {
    final f = BudgetFixture()..modelStatuses.addAll([503, 503, 503, 503]);
    await f.start();
    addTearDown(f.close);
    final w = f.workspaces.first;
    final note = await w.captureText(title: '手动重试', text: '同一份原文。');
    final first = await w.processTextNote(note.id);
    final held = w.budget.reservedCnyMicros;
    final last = await w.retryTextProcessing(first.id);
    expect(last.id, first.id);
    expect(last.status, TextProcessingStatus.costPending);
    expect(last.attemptCount, 5);
    expect(w.budget.reservedCnyMicros, held);
    expect(w.budget.spentCnyMicros, greaterThan(0));
    expect(w.notes.single.id, note.id);
    expect(w.notes.single.text, '整理后的普通想法。');
  });
  test('an explicitly re-prepared cancelled job uses a fresh reservation and can settle without counting its released attempt as unknown', () async {
    final f = BudgetFixture();
    await f.start();
    addTearDown(f.close);
    final w = f.workspaces.first;
    final note = await w.captureText(title: '重新决定', text: '同一份普通想法。');
    final before = await w.prepareTextProcessing(note.id);
    await w.cancelTextProcessing(before.id);
    final again = await w.prepareTextProcessing(note.id);
    expect(again.status, TextProcessingStatus.prepared);
    expect(again.id, before.id);
    final complete = await w.processTextNote(note.id);
    expect(complete.status, TextProcessingStatus.completed);
    expect(w.budget.reservedCnyMicros, 0);
    expect(f.modelRequests.length, 1);
    expect(w.notes.length, 1);
  });
  test('an expired quote after budget refusal is refreshed without paid dispatch or lost local content', () async {
    final f = BudgetFixture();
    await f.start();
    addTearDown(f.close);
    final w = f.workspaces.first;
    await w.setMonthlyBudgetLimit(1);
    final note = await w.captureText(title: '额度不足', text: '仍然先保存普通原文。');
    final failed = await w.prepareTextProcessing(note.id);
    expect(failed.status, TextProcessingStatus.failed);
    await f.advanceTo(DateTime.now().toUtc().add(const Duration(minutes: 11)));
    await w.setMonthlyBudgetLimit(30000000);
    final ready = await w.prepareTextProcessing(note.id);
    expect(ready.id, failed.id);
    expect(ready.status, TextProcessingStatus.prepared);
    expect(f.modelRequests, isEmpty);
    expect(w.notes.single.originalText, note.text);
  });
  test('reconciliation releases a hold only when the shared ledger proves dispatch never occurred', () async {
    final f = BudgetFixture();
    await f.start();
    addTearDown(f.close);
    final w = f.workspaces.first;
    final note = await w.captureText(title: '凭据移除', text: '保存后再决定是否发送。');
    final ready = await w.prepareTextProcessing(note.id);
    await w.connection.disconnectOpenRouter();
    await w.processTextNote(note.id);
    expect(w.budget.reservedCnyMicros, greaterThan(0));
    await f.reopen(0);
    final reconciled = await f.workspaces.first.reconcileTextProcessing(
      ready.id,
    );
    expect(reconciled.status, TextProcessingStatus.cancelled);
    expect(f.workspaces.first.budget.reservedCnyMicros, 0);
    expect(f.modelRequests, isEmpty);
    expect(f.workspaces.first.notes.single.originalText, note.text);
  });
  test('a generation collision retains the old charge and the unresolved new hold and pauses all devices across restart', () async {
    final f = BudgetFixture()..reuseGenerationId = true;
    await f.start();
    addTearDown(f.close);
    final owner = f.workspaces.first;
    final first = await owner.captureText(title: '第一笔回执', text: '普通想法一。');
    await owner.processTextNote(first.id);
    final charged = owner.budget.spentCnyMicros;
    final second = await owner.captureText(title: '重复费用编号', text: '普通想法二。');
    await owner.processTextNote(second.id);
    final held = owner.budget.reservedCnyMicros;
    expect(held, greaterThan(0));
    expect(owner.budget.spentCnyMicros, charged);
    expect(owner.budget.paused, isTrue);
    await f.reopen(0);
    await f.workspaces.last.refreshBudget();
    expect(f.workspaces.last.budget.paused, isTrue);
    expect(f.workspaces.last.budget.reservedCnyMicros, held);
    expect(f.workspaces.last.budget.spentCnyMicros, charged);
    final local = await f.workspaces.last.captureText(
      title: '冲突后继续收集',
      text: '仍可本地保存。',
    );
    expect(
      (await f.workspaces.last.prepareTextProcessing(local.id)).status,
      TextProcessingStatus.failed,
    );
    expect(f.modelRequests.length, 2);
  });
}
