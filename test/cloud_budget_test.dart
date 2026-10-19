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
}
