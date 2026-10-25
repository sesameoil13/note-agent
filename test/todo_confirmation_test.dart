import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/note_workspace.dart';

import 'support/budget_fixture.dart';

Map<String, dynamic> action(
  String text, {
  String reason = 'none',
  String time = '',
  String timeStatus = 'absent',
}) => {
  'text': text,
  'reason': reason,
  'timeExpression': time,
  'timeStatus': timeStatus,
};

void main() {
  test('local type changes preserve existing associations and attached sources and refuse newer external body edits', () async {
    final root = await Directory.systemTemp.createTemp('action-sources-');
    final w = await NoteWorkspace.open(
      localDirectory: Directory('${root.path}/local'),
      vaultDirectory: await Directory('${root.path}/vault').create(),
    );
    addTearDown(() async {
      await w.close();
      await root.delete(recursive: true);
    });
    final n = await w.captureText(title: '保留关联', text: '需要买电池。');
    final file = await File('${root.path}/source.txt').writeAsString('附件原件。');
    await w.attachFile(noteId: n.id, original: file);
    final markdown = await File(n.notePath).readAsString();
    final linked = markdown.replaceFirst('暂无关联', '[[家用物品]]');
    await File(n.notePath).writeAsString(linked);
    final sourceSection = linked
        .substring(linked.indexOf('## 来源'))
        .split('\n记录：')
        .first;
    final changed = await w.resolveNoteActions(
      n.id,
      kind: NoteKind.todo,
      actions: [
        const WorkspaceAction(text: '买电池', decision: ActionDecision.confirmed),
      ],
      body: '补充电池。\n## 不得增加板块',
    );
    final after = await File(changed.notePath).readAsString();
    expect(after, contains('[[家用物品]]'));
    expect(after, contains(sourceSection));
    expect(
      RegExp(r'^## (.+)$', multiLine: true).allMatches(after).map((m) => m[1]),
      ['待办', '摘要', '关联', '来源'],
    );
    final edited = after.replaceFirst('补充电池。', '后来在 Obsidian 修改的摘要。');
    await File(changed.notePath).writeAsString(edited);
    await expectLater(
      w.resolveNoteActions(n.id, kind: NoteKind.ordinary, actions: []),
      throwsA(isA<FileSystemException>()),
    );
    expect(await File(changed.notePath).readAsString(), edited);
    expect(w.notes.single.kind, NoteKind.todo);
  });
  test('mixed content confirms a clear action while another uncertain action remains gated', () async {
    final f = BudgetFixture()
      ..modelResult = {
        'kind': 'review',
        'title': '混合行动',
        'body': '采购与建议分别记录。',
        'actions': [action('买电池'), action('买新遥控器', reason: 'hypothesis')],
      };
    await f.start();
    addTearDown(f.close);
    final w = f.workspaces.first;
    final n = await w.captureText(title: '混合内容', text: '我需要买电池，也许可以买个新遥控器。');
    await w.processTextNote(n.id);
    expect(w.notes.single.kind, NoteKind.todo);
    expect(w.notes.single.actions.first.actionConfirmed, isTrue);
    expect(w.notes.single.actions.last.actionConfirmed, isFalse);
    expect(w.pendingActionNotes.single.id, n.id);
  });
  test('a pending file write survives restart and can be explicitly retried without duplicates', () async {
    final root = await Directory.systemTemp.createTemp('action-save-');
    final vault = await Directory('${root.path}/vault').create();
    final storage = _FailActionStorage(vault);
    final local = Directory('${root.path}/local');
    var w = await NoteWorkspace.open(
      localDirectory: local,
      vaultStorage: storage,
    );
    final n = await w.captureText(title: '本地待办', text: '需要买电池。');
    storage.fail = true;
    await expectLater(
      w.resolveNoteActions(
        n.id,
        kind: NoteKind.todo,
        actions: [
          const WorkspaceAction(
            id: 'stable-action',
            text: '买电池',
            decision: ActionDecision.confirmed,
          ),
        ],
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(w.notes.single.kind, NoteKind.ordinary);
    expect(w.notes.single.actionSavePending, isTrue);
    storage.fail = false;
    await expectLater(
      w.renameNote(n.id, title: '改名会移动待恢复文件'),
      throwsA(isA<StateError>()),
    );
    expect(w.notes.single.notePath, n.notePath);
    expect(await File(n.sourcePath).readAsString(), n.text);
    storage.fail = true;
    await w.close();
    w = await NoteWorkspace.open(localDirectory: local, vaultStorage: storage);
    expect(w.notes.single.actionSavePending, isTrue);
    await expectLater(
      w.renameNote(n.id, title: '重启后仍须先恢复'),
      throwsA(isA<StateError>()),
    );
    storage.fail = false;
    await w.retryNoteActionSave(n.id);
    expect(w.notes.single.actionSavePending, isFalse);
    expect(w.notes.single.actions.single.id, 'stable-action');
    expect(w.notes.single.originalText, n.text);
    await w.renameNote(n.id, title: '恢复后可正常改名');
    expect(w.notes.single.title, '恢复后可正常改名');
    expect(w.notes.single.id, n.id);
    await w.close();
    w = await NoteWorkspace.open(localDirectory: local, vaultStorage: storage);
    expect(w.notes.single.actions.length, 1);
    expect(w.textJobs, isEmpty);
    await w.close();
    await root.delete(recursive: true);
  });
  test('local removal and ordinary correction survive later reconciliation without recreating actions', () async {
    final f = BudgetFixture()
      ..modelResult = {
        'kind': 'todo',
        'title': '采购用品',
        'body': '补充家用物品。',
        'actions': [action('买电池'), action('买纸巾')],
      };
    await f.start();
    addTearDown(f.close);
    final w = f.workspaces.first;
    final n = await w.captureText(title: '采购', text: '我需要买电池和纸巾。');
    final j = await w.processTextNote(n.id);
    final last = w.notes.single.actions.last;
    await w.resolveNoteActions(n.id, kind: NoteKind.todo, actions: [last]);
    expect(w.notes.single.actions.single.id, last.id);
    await w.resolveNoteActions(n.id, kind: NoteKind.ordinary, actions: []);
    f.generationAvailable = true;
    f.generationCost = 0.00001;
    await w.reconcileTextProcessing(j.id);
    await f.reopen(0);
    expect(f.workspaces.first.notes.single.actions, isEmpty);
    expect(f.workspaces.first.notes.single.text, n.text);
    expect(f.modelRequests.length, 1);
  });
  test('a local type correction during an in-flight paid result cannot be overwritten by that result', () async {
    final f = BudgetFixture()
      ..modelResult = {
        'kind': 'todo',
        'title': '购买电池',
        'body': '补充电池。',
        'actions': [action('买电池')],
      };
    await f.start();
    addTearDown(f.close);
    final w = f.workspaces.first;
    final n = await w.captureText(title: '用户决定', text: '原始记录保留。');
    f.beforeReply = () async {
      await w.resolveNoteActions(
        n.id,
        kind: NoteKind.ordinary,
        actions: [],
        body: '我已经自行修正了这条普通记录。',
      );
    };
    await w.processTextNote(n.id);
    expect(w.notes.single.text, '我已经自行修正了这条普通记录。');
    expect(w.notes.single.kind, NoteKind.ordinary);
    expect(w.budget.spentCnyMicros, greaterThan(0));
    expect(w.budget.reservedCnyMicros, 0);
    await f.reopen(0);
    expect(f.workspaces.first.notes.single.text, '我已经自行修正了这条普通记录。');
    expect(f.modelRequests.length, 1);
  });
  test('invalid action contracts retain the original and account for the paid response', () async {
    final f = BudgetFixture();
    await f.start();
    addTearDown(f.close);
    final w = f.workspaces.first;
    final invalid = [
      {
        'kind': 'todo',
        'sourceId': 'wrong-source',
        'actions': [action('买电池')],
      },
      {
        'kind': 'ordinary',
        'actions': [action('买电池')],
      },
      {
        'kind': 'todo',
        'actions': [action('买电池', reason: 'invented')],
      },
      {
        'kind': 'todo',
        'actions': [action('买电池', time: '后天七点', timeStatus: 'explicit')],
      },
      {'kind': 'todo', 'actions': List.generate(21, (_) => action('买电池'))},
    ];
    for (var i = 0; i < invalid.length; i++) {
      f.modelResult = {'title': '核对原文', 'body': '不能应用无效结果。', ...invalid[i]};
      final n = await w.captureText(title: '格式核对$i', text: '我需要买电池。');
      final original = await File(n.notePath).readAsString();
      final j = await w.processTextNote(n.id);
      expect(j.status, TextProcessingStatus.review);
      expect(w.notes.firstWhere((x) => x.id == n.id).actions, isEmpty);
      expect(await File(n.notePath).readAsString(), original);
      expect(j.knownCostUsdNanos, 10000);
    }
    expect(f.modelRequests.length, invalid.length);
  });
  test('clear action produces the todo template and retains the complete original across restart', () async {
    final f = BudgetFixture()
      ..modelResult = {
        'kind': 'todo',
        'title': '购买电池',
        'body': '遥控器需要更换电池。',
        'actions': [action('买两节电池')],
      };
    await f.start();
    addTearDown(f.close);
    final w = f.workspaces.first;
    const original = '遥控器没电了。我需要买两节电池。';
    final note = await w.captureText(title: '原始记录', text: original);
    final source = await File(note.sourcePath).readAsBytes();
    await w.processTextNote(note.id);
    final result = w.notes.single;
    final markdown = await File(result.notePath).readAsString();
    expect(
      RegExp(
        r'^## (.+)$',
        multiLine: true,
      ).allMatches(markdown).map((m) => m[1]),
      ['待办', '摘要', '关联', '来源'],
    );
    expect(markdown, contains('- [ ] 买两节电池'));
    expect(await File(result.sourcePath).readAsBytes(), source);
    expect(result.originalText, original);
    await f.reopen(0);
    expect(
      await File(f.workspaces.first.notes.single.notePath).readAsString(),
      markdown,
    );
    expect(f.workspaces.first.notes.single.originalText, original);
    expect(f.modelRequests.length, 1);
  });
  test('quoted, hypothetical, negated and unclear-owner actions wait for a local decision independently of time', () async {
    final f = BudgetFixture();
    await f.start();
    addTearDown(f.close);
    for (final reason in [
      'quote',
      'hypothesis',
      'negated',
      'unclearResponsibility',
    ]) {
      f.modelResult = {
        'kind': 'review',
        'title': '行动待核对',
        'body': '仅记录表达，不表示承诺。',
        'actions': [
          action('发出报告', reason: reason, time: '明天九点', timeStatus: 'explicit'),
        ],
      };
      final w = f.workspaces.first;
      final note = await w.captureText(
        title: '待核对$reason',
        text: '来源$reason：明天九点发出报告。',
      );
      await w.processTextNote(note.id);
      final pending = w.notes.firstWhere((n) => n.id == note.id);
      expect(pending.actions.single.actionConfirmed, isFalse);
      expect(pending.actions.single.timeStatus, ActionTimeStatus.explicit);
      expect(w.pendingActionNotes.map((n) => n.id), contains(note.id));
      final id = pending.actions.single.id;
      final accepted = await w.resolveNoteActions(
        note.id,
        kind: NoteKind.todo,
        actions: [
          WorkspaceAction(
            id: id,
            text: '由我发送修订报告',
            decision: ActionDecision.confirmed,
          ),
        ],
      );
      expect(accepted.actions.single.id, id);
      expect(accepted.actions.single.actionConfirmed, isTrue);
      expect(accepted.actions.single.timeStatus, ActionTimeStatus.absent);
      expect(w.pendingActionNotes.map((n) => n.id), isNot(contains(note.id)));
      expect(
        await File(accepted.sourcePath).readAsString(),
        contains(note.text),
      );
    }
    expect(f.modelRequests.length, 4);
    await f.reopen(0);
    expect(f.workspaces.first.pendingActionNotes, isEmpty);
    expect(
      f.workspaces.first.notes.every((n) => n.actions.single.actionConfirmed),
      isTrue,
    );
    expect(f.modelRequests.length, 4);
  });
  test('a legacy review can be corrected to ordinary locally without losing unknown fees or resending', () async {
    final f = BudgetFixture()
      ..omitCost = true
      ..modelResult = {
        'kind': 'review',
        'title': '保留观察',
        'body': '模型旧格式待确认内容。',
      };
    await f.start();
    addTearDown(f.close);
    final w = f.workspaces.first;
    final note = await w.captureText(title: '雨后观察', text: '树叶变绿，空气有泥土的气味。');
    final job = await w.processTextNote(note.id);
    final held = w.budget.reservedCnyMicros;
    expect(held, greaterThan(0));
    await w.setMonthlyBudgetLimit(1);
    expect(w.pendingActionNotes.single.id, note.id);
    final result = await w.resolveNoteActions(
      note.id,
      kind: NoteKind.ordinary,
      actions: [],
    );
    expect(result.kind, NoteKind.ordinary);
    expect(result.text, note.text);
    expect(result.actions, isEmpty);
    expect(w.pendingActionNotes, isEmpty);
    await f.reopen(0);
    final restored = f.workspaces.first;
    await restored.reconcileTextProcessing(job.id);
    await restored.refreshBudget();
    expect(restored.budget.reservedCnyMicros, held);
    expect(restored.pendingActionNotes, isEmpty);
    expect(f.modelRequests.length, 1);
    f.generationAvailable = true;
    await restored.reconcileTextProcessing(job.id);
    expect(restored.budget.reservedCnyMicros, 0);
    final markdown = await File(restored.notes.single.notePath).readAsString();
    expect(
      RegExp(
        r'^## (.+)$',
        multiLine: true,
      ).allMatches(markdown).map((m) => m[1]),
      ['正文', '关联', '来源'],
    );
    expect(restored.notes.single.originalText, note.text);
    expect(f.modelRequests.length, 1);
  });
}

class _FailActionStorage extends DirectoryVaultStorage {
  _FailActionStorage(super.directory);
  bool fail = false;
  @override
  Future<void> replaceText(
    String path,
    String expected,
    String text,
    String operation,
  ) {
    if (fail && operation.startsWith('action-')) {
      throw const FileSystemException('controlled unavailable vault');
    }
    return super.replaceText(path, expected, text, operation);
  }
}
