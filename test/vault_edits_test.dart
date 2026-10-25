import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:note_agent/note_workspace.dart';

import 'support/pending_notification_fixture.dart';

void main() {
  late Directory root;
  late PendingNotifications port;
  late DateTime now;

  Future<NoteWorkspace> open() async {
    final w = await NoteWorkspace.open(
      localDirectory: Directory('${root.path}/local'),
      vaultDirectory: Directory('${root.path}/vault'),
      clock: () => now,
      notifications: port,
    );
    addTearDown(w.close);
    return w;
  }

  File noteFile(NoteWorkspace w, String id) =>
      File(w.notes.firstWhere((x) => x.id == id).notePath);

  /// Simulates Obsidian (or Sync delivering another device's copy) writing the
  /// file with that device's original modification time.
  Future<void> externalWrite(File file, String text, DateTime mtime) async {
    await file.writeAsString(text);
    await file.setLastModified(mtime);
  }

  Future<WorkspaceNote> todo(NoteWorkspace w) async {
    final n = await w.captureText(title: '安排', text: '明天十点买电池，联系物业。');
    return w.resolveNoteActions(
      n.id,
      kind: NoteKind.todo,
      actions: const [
        WorkspaceAction(
          id: 'buy',
          text: '买电池',
          decision: ActionDecision.confirmed,
          reason: 'none',
          timeStatus: ActionTimeStatus.explicit,
          timeExpression: '明天10:00',
        ),
        WorkspaceAction(
          id: 'call',
          text: '联系物业',
          decision: ActionDecision.confirmed,
          reason: 'none',
        ),
      ],
    );
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('vault-edits-');
    await Directory('${root.path}/vault').create();
    port = PendingNotifications();
    now = DateTime(2026, 10, 21, 8);
    addTearDown(() => root.delete(recursive: true));
  });

  test(
    'a later Obsidian edit to an ordinary note updates the App view once',
    () async {
      final w = await open();
      final n = await w.captureText(title: '读书', text: '第一章笔记');
      final file = noteFile(w, n.id);
      final edited = (await file.readAsString()).replaceFirst(
        '第一章笔记',
        '第一章笔记\n补充：作者观点',
      );
      final edit = DateTime(2026, 10, 21, 9, 30);
      await externalWrite(file, edited, edit);

      expect(await w.readVaultEdits(), [n.id]);
      final note = w.notes.single;
      expect(note.text, '第一章笔记\n补充：作者观点');
      expect(note.modifiedAt, edit);
      expect(note.createdAt, n.createdAt);
      // The note's own modification line follows the adopted edit.
      expect(await file.readAsString(), contains('修改：${formatNoteTime(edit)}'));

      // Neither the adopted edit nor the App's own time-line write echoes back.
      expect(await w.readVaultEdits(), isEmpty);
      await w.close();
      final reopened = await open();
      expect(reopened.notes.single.text, '第一章笔记\n补充：作者观点');
      expect(await reopened.readVaultEdits(), isEmpty);
    },
  );

  test(
    'an older copy that arrives late does not replace newer content',
    () async {
      final w = await open();
      final n = await w.captureText(title: '读书', text: '第二版');
      final file = noteFile(w, n.id);
      final mine = await file.readAsString();
      // Another device edited offline at 07:00; Sync delivers it after 08:00.
      await externalWrite(
        file,
        mine.replaceFirst('第二版', '第一版'),
        DateTime(2026, 10, 21, 7),
      );

      expect(await w.readVaultEdits(), isEmpty);
      expect(w.notes.single.text, '第二版');
      expect(w.notes.single.modifiedAt, now);
      // The newer version is written back once and is not read as a new edit.
      expect(await file.readAsString(), mine);
      expect(await w.readVaultEdits(), isEmpty);
      expect(await file.readAsString(), mine);
    },
  );

  test(
    'equal timestamps use a stable content tiebreak without asking',
    () async {
      final w = await open();
      final n = await w.captureText(title: '读书', text: '乙');
      final file = noteFile(w, n.id);
      final mine = await file.readAsString();

      // Same device time, content ordering decides: '丙' < '乙' (code units)
      // keeps the App's version on every device.
      await externalWrite(file, mine.replaceFirst('乙', '丙'), now);
      expect(await w.readVaultEdits(), isEmpty);
      expect(w.notes.single.text, '乙');
      expect(await file.readAsString(), mine);

      // '甲' > '乙' wins from the same timestamp.
      await externalWrite(file, mine.replaceFirst('乙', '甲'), now);
      expect(await w.readVaultEdits(), [n.id]);
      expect(w.notes.single.text, '甲');
      expect(w.pendingConfirmationItems, isEmpty);
    },
  );

  test(
    'an edit in the same second as the App write is compared at whole seconds',
    () async {
      // The App wrote at 08:00:00.700; a file system with one-second mtimes
      // reports an Obsidian edit made in that second as 08:00:00.
      now = DateTime(2026, 10, 21, 8, 0, 0, 700);
      final w = await open();
      final n = await w.captureText(title: '读书', text: '乙');
      final file = noteFile(w, n.id);
      final mine = await file.readAsString();

      await externalWrite(
        file,
        mine.replaceFirst('乙', '甲'),
        DateTime(2026, 10, 21, 8),
      );
      expect(await w.readVaultEdits(), [n.id]);
      expect(w.notes.single.text, '甲');

      // The tie is decided by content, the same on every device.
      final adopted = await file.readAsString();
      final written = w.notes.single.modifiedAt;
      await externalWrite(
        file,
        adopted.replaceFirst('甲', '丙'),
        DateTime(
          written.year,
          written.month,
          written.day,
          written.hour,
          written.minute,
          written.second,
        ),
      );
      expect(await w.readVaultEdits(), isEmpty);
      expect(w.notes.single.text, '甲');
    },
  );

  test(
    'ticking a to-do in Obsidian completes it and cancels its reminder',
    () async {
      final w = await open();
      final n = await todo(w);
      expect(w.reminders.map((r) => r.actionId), ['buy', 'call']);
      final file = noteFile(w, n.id);
      await externalWrite(
        file,
        (await file.readAsString()).replaceFirst('- [ ] 买电池', '- [x] 买电池'),
        DateTime(2026, 10, 21, 9),
      );

      expect(await w.readVaultEdits(), [n.id]);
      final state = w.actionState(n.id, 'buy');
      expect(
        (state.completed, state.lifecycle, state.notePending),
        (true, 1, false),
      );
      expect(w.reminders.map((r) => r.actionId), ['call']);
      expect(
        port.pending.values.where((r) => r.payload['actionId'] == 'buy'),
        isEmpty,
      );
      expect(await w.readVaultEdits(), isEmpty);
    },
  );

  test('unticking in Obsidian never revives a completed lifecycle', () async {
    final w = await open();
    final n = await todo(w);
    await w.completeAction(n.id, 'buy');
    final file = noteFile(w, n.id);
    expect(await file.readAsString(), contains('- [x] 买电池'));
    await externalWrite(
      file,
      (await file.readAsString()).replaceFirst('- [x] 买电池', '- [ ] 买电池'),
      DateTime(2026, 10, 21, 9),
    );

    await w.readVaultEdits();
    expect(w.actionState(n.id, 'buy').completed, true);
    expect(w.reminders.map((r) => r.actionId), ['call']);
    // The authoritative completion is mirrored back to the checkbox.
    expect(await file.readAsString(), contains('- [x] 买电池'));
    expect(await w.readVaultEdits(), isEmpty);
  });

  test('changing a to-do time in Obsidian moves its reminder', () async {
    final w = await open();
    final n = await todo(w);
    final file = noteFile(w, n.id);
    final before = await file.readAsString();
    expect(before, contains('- [ ] 买电池 ⏰ 明天10:00\n- [ ] 联系物业\n'));
    final old = w.reminders.firstWhere((r) => r.actionId == 'buy');
    expect(old.time, DateTime(2026, 10, 22, 10));

    await externalWrite(
      file,
      before
          .replaceFirst('⏰ 明天10:00', '⏰ 后天15:30')
          .replaceFirst('- [ ] 联系物业', '- [ ] 联系物业 ⏰ 明天下午'),
      DateTime(2026, 10, 21, 9),
    );
    expect(await w.readVaultEdits(), [n.id]);

    final buy = w.reminders.firstWhere((r) => r.actionId == 'buy');
    expect(buy.time, DateTime(2026, 10, 23, 15, 30));
    expect(buy.explicitTime, true);
    expect(buy.id, isNot(old.id));
    expect(port.pending.containsKey(old.id), false);
    expect(port.pending[buy.id]!.time, DateTime(2026, 10, 23, 15, 30));
    final call = w.reminders.firstWhere((r) => r.actionId == 'call');
    expect(call.time, DateTime(2026, 10, 22, 14));
    final action = w.notes.single.actions.firstWhere((a) => a.id == 'buy');
    expect(action.timeExpression, '后天15:30');
    expect(await w.readVaultEdits(), isEmpty);
  });

  test('a late copy ticked in an earlier lifecycle does not close a reopened to-do, but a current tick does', () async {
    final w = await open();
    final n = await todo(w);
    final file = noteFile(w, n.id);
    final unticked = await file.readAsString();

    now = DateTime(2026, 10, 21, 10);
    await w.completeAction(n.id, 'buy');
    now = DateTime(2026, 10, 21, 11);
    await w.reopenAction(n.id, 'buy', DateTime(2026, 10, 24, 9));
    expect(w.actionState(n.id, 'buy').lifecycle, 2);

    // Another device ticked at 09:30, during lifecycle 1; it arrives late.
    await externalWrite(
      file,
      unticked.replaceFirst('- [ ] 买电池', '- [x] 买电池'),
      DateTime(2026, 10, 21, 9, 30),
    );
    await w.readVaultEdits();
    expect(w.actionState(n.id, 'buy').completed, false);
    expect(
      w.reminders.firstWhere((r) => r.actionId == 'buy').time,
      DateTime(2026, 10, 24, 9),
    );
    expect(await file.readAsString(), contains('- [ ] 买电池'));

    // An older copy (losing on content) still carries a valid current tick.
    final current = await file.readAsString();
    await externalWrite(
      file,
      current
          .replaceFirst('- [ ] 联系物业', '- [x] 联系物业')
          .replaceFirst('明天十点', '旧摘要'),
      DateTime(2026, 10, 21, 10, 30),
    );
    expect(await w.readVaultEdits(), [n.id]);
    expect(w.actionState(n.id, 'call').completed, true);
    expect(w.notes.single.text, isNot(contains('旧摘要')));
    expect(await file.readAsString(), contains('- [x] 联系物业'));
  });

  test('a note renamed or moved in Obsidian keeps its identity and later writes follow it', () async {
    final w = await open();
    final n = await todo(w);
    final old = noteFile(w, n.id);
    await Directory('${root.path}/vault/项目').create();
    final moved = await old.rename('${root.path}/vault/项目/物业事项.md');

    expect(await w.readVaultEdits(), [n.id]);
    final note = w.notes.single;
    expect(note.id, n.id);
    expect(note.title, '物业事项');
    expect(note.notePath, endsWith(p.join('vault', '项目', '物业事项.md')));
    expect(note.status, NoteStatus.localSaved);
    expect(w.search('物业事项').map((x) => x.id), [n.id]);
    expect(await w.readVaultEdits(), isEmpty);

    // A rename plus an edit in the same session: both are read.
    await externalWrite(
      moved,
      (await moved.readAsString()).replaceFirst('- [ ] 联系物业', '- [x] 联系物业'),
      DateTime(2026, 10, 21, 9),
    );
    expect(await w.readVaultEdits(), [n.id]);
    expect(w.actionState(n.id, 'call').completed, true);

    await w.completeAction(n.id, 'buy');
    expect(await moved.readAsString(), contains('- [x] 买电池'));
    expect(old.existsSync(), false);
  });

  test('edits made while the App was closed are read when it opens', () async {
    var w = await open();
    final n = await todo(w);
    final file = noteFile(w, n.id);
    await w.close();
    await externalWrite(
      file,
      (await file.readAsString()).replaceFirst('- [ ] 买电池', '- [x] 买电池'),
      DateTime(2026, 10, 21, 9),
    );

    w = await open();
    expect(w.actionState(n.id, 'buy').completed, true);
    expect(w.reminders.map((r) => r.actionId), ['call']);
    expect(await w.readVaultEdits(), isEmpty);
  });

  test('to-do text edited in Obsidian keeps identities; an added line waits for confirmation without a reminder', () async {
    final w = await open();
    final n = await todo(w);
    final file = noteFile(w, n.id);
    await externalWrite(
      file,
      (await file.readAsString()).replaceFirst(
        '- [ ] 联系物业\n',
        '- [ ] 联系物业维修\n- [ ] 交电费 ⏰ 明天20:00\n',
      ),
      DateTime(2026, 10, 21, 9),
    );

    expect(await w.readVaultEdits(), [n.id]);
    final actions = w.notes.single.actions;
    expect(actions.map((a) => a.text), ['买电池', '联系物业维修', '交电费']);
    expect(actions[1].id, 'call');
    // A line typed in Obsidian has not been confirmed as an action yet.
    expect(actions[2].actionConfirmed, false);
    expect(actions[2].timeExpression, '明天20:00');
    expect(w.reminders.map((r) => r.actionId), ['buy', 'call']);
    expect(
      port.pending.values.where((r) => r.payload['actionId'] == actions[2].id),
      isEmpty,
    );
    expect(w.pendingConfirmationItems.map((i) => (i.kind, i.subjectId)), [
      (PendingConfirmationKind.action, actions[2].id),
    ]);
    expect(w.reminders.firstWhere((r) => r.actionId == 'call').text, '联系物业维修');
    // The note shows the line as pending, and that rewrite is not an edit.
    expect(await file.readAsString(), contains('- [ ] 交电费 ⏰ 明天20:00（待确认）\n'));
    expect(await w.readVaultEdits(), isEmpty);
    expect(w.notes.single.actions[2].actionConfirmed, false);

    // Confirming it in the App starts its reminder.
    await w.resolveNoteActions(
      n.id,
      kind: NoteKind.todo,
      actions: [
        for (final a in w.notes.single.actions)
          WorkspaceAction(
            id: a.id,
            text: a.text,
            decision: ActionDecision.confirmed,
            reason: 'none',
            timeExpression: a.timeExpression,
            timeStatus: a.timeStatus,
          ),
      ],
    );
    final added = w.reminders.firstWhere((r) => r.actionId == actions[2].id);
    expect(added.time, DateTime(2026, 10, 22, 20));
  });

  test('deleting to and restoring from the recycle bin is not read as an Obsidian edit or rename', () async {
    final w = await open();
    final n = await todo(w);
    final other = await w.captureText(title: '读书', text: '第一章笔记');
    final markdown = await noteFile(w, n.id).readAsString();
    await w.deleteNote(n.id);
    expect(await w.readVaultEdits(), isEmpty);
    // A same-named note while it is deleted makes the restore take a new path.
    await w.captureText(title: '安排', text: '另一份安排');
    expect(await w.readVaultEdits(), isEmpty);
    now = DateTime(2026, 10, 21, 9);

    final restored = await w.restoreNote(n.id);
    expect(restored.title, '安排 (2)');
    final file = noteFile(w, n.id);
    final restoredText = await file.readAsString();
    await file.setLastModified(DateTime(2026, 10, 21, 9, 30));
    expect(await w.readVaultEdits(), isEmpty);
    expect(await file.readAsString(), restoredText);
    expect(
      restoredText.split('\n## 关联\n').first,
      markdown.split('\n## 关联\n').first,
    );
    expect(w.notes.firstWhere((x) => x.id == n.id).title, '安排 (2)');
    expect(w.notes.firstWhere((x) => x.id == other.id).title, '读书');
    expect(w.actionState(n.id, 'buy').completed, isFalse);
    expect(w.reminders.map((r) => r.actionId), containsAll(['buy', 'call']));
  });
}
