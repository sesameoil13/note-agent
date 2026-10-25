import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/note_workspace.dart';

import 'support/budget_fixture.dart';
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

  Future<WorkspaceNote> todo(
    NoteWorkspace w, {
    String title = '安排',
    String time = '明天10:00',
  }) async {
    final n = await w.captureText(title: title, text: '明天十点买电池。');
    return w.resolveNoteActions(
      n.id,
      kind: NoteKind.todo,
      actions: [
        WorkspaceAction(
          id: 'buy',
          text: '买电池',
          decision: ActionDecision.confirmed,
          reason: 'none',
          timeStatus: ActionTimeStatus.explicit,
          timeExpression: time,
        ),
      ],
    );
  }

  List<NotificationRequest> alerts() => port.pending.values
      .where((r) => r.payload['kind'] == 'actionReminder')
      .toList();

  File vault(String relative) => File('${root.path}/vault/$relative');

  setUp(() async {
    root = await Directory.systemTemp.createTemp('recycle-bin-');
    await Directory('${root.path}/vault').create();
    port = PendingNotifications();
    now = DateTime(2026, 10, 21, 8);
    addTearDown(() => root.delete(recursive: true));
  });

  test('archiving hides a note from the daily list but keeps its file and reminder, across restart', () async {
    var w = await open();
    final n = await todo(w);
    final file = await vault('安排.md').readAsString();

    await w.archiveNote(n.id);
    expect(w.dailyNotes.map((x) => x.id), isNot(contains(n.id)));
    expect(w.archivedNotes.single.id, n.id);
    expect(await vault('安排.md').readAsString(), file);
    expect(alerts().single.time, DateTime(2026, 10, 22, 10));

    await w.close();
    w = await open();
    expect(w.archivedNotes.single.id, n.id);
    expect(alerts(), hasLength(1));

    await w.unarchiveNote(n.id);
    expect(w.dailyNotes.single.id, n.id);
    expect(w.archivedNotes, isEmpty);
  });

  test('deleting moves a note into the 回收站, cancels its reminder, keeps the source and never auto-empties', () async {
    var w = await open();
    final n = await todo(w);
    final markdown = await vault('安排.md').readAsString();
    final source = await vault('attachments/note-agent/${n.id}.txt')
        .readAsString();
    expect(alerts(), hasLength(1));

    await w.deleteNote(n.id);
    expect(w.notes, isEmpty);
    expect(w.reminders, isEmpty);
    expect(alerts(), isEmpty);
    expect(vault('安排.md').existsSync(), isFalse);
    expect(
      await vault('attachments/note-agent/${n.id}.txt').readAsString(),
      source,
    );
    final item = w.recycleBin.single;
    expect(item.noteId, n.id);
    expect(item.title, '安排');
    expect(item.deletedAt, now);
    expect(item.markdown, markdown);

    now = now.add(const Duration(days: 400));
    await w.close();
    w = await open();
    expect(w.notes, isEmpty);
    expect(alerts(), isEmpty);
    expect(w.recycleBin.single.noteId, n.id);
    expect(vault('安排.md').existsSync(), isFalse);
  });

  test('restoring brings back the same file and reschedules a future reminder under a new notification id', () async {
    final w = await open();
    final n = await todo(w);
    final markdown = await vault('安排.md').readAsString();
    final before = alerts().single;

    await w.deleteNote(n.id);
    now = now.add(const Duration(hours: 1));
    final restored = await w.restoreNote(n.id);

    expect(restored.title, '安排');
    expect(restored.titleCollision, isFalse);
    expect(w.recycleBin, isEmpty);
    expect(w.dailyNotes.single.id, n.id);
    expect(await vault('安排.md').readAsString(), markdown);
    final after = alerts().single;
    expect(after.time, before.time);
    expect(after.id, isNot(before.id));
    expect(w.reminders.single.status, ReminderStatus.scheduled);
    expect(w.reminderDecisions, isEmpty);
  });

  test(
    'restoring never overwrites a same-named note; it takes a numbered title',
    () async {
      final w = await open();
      final old = await w.captureText(title: '周报', text: '旧的周报');
      final oldMarkdown = await vault('周报.md').readAsString();
      await w.deleteNote(old.id);
      final replacement = await w.captureText(title: '周报', text: '新的周报');
      final newMarkdown = await vault('周报.md').readAsString();

      final restored = await w.restoreNote(old.id);

      expect(restored.title, '周报 (2)');
      expect(restored.titleCollision, isTrue);
      expect(await vault('周报.md').readAsString(), newMarkdown);
      expect(await vault('周报 (2).md').readAsString(), oldMarkdown);
      expect(w.notes.firstWhere((n) => n.id == replacement.id).title, '周报');
    },
  );

  test('a reminder that passed while deleted waits for a decision in the App, across restart', () async {
    var w = await open();
    final n = await todo(w);
    await w.deleteNote(n.id);
    now = DateTime(2026, 10, 23, 8);

    await w.restoreNote(n.id);
    expect(alerts(), isEmpty);
    expect(w.reminders, isEmpty);
    final decision = w.reminderDecisions.single;
    expect(decision.noteId, n.id);
    expect(decision.actionId, 'buy');
    expect(decision.missedTime, DateTime(2026, 10, 22, 10));
    expect(w.actionState(n.id, 'buy').completed, isFalse);

    await w.close();
    w = await open();
    expect(alerts(), isEmpty);
    expect(w.reminderDecisions, hasLength(1));

    await w.decideRestoredReminder(n.id, 'buy', DateTime(2026, 10, 23, 18));
    expect(w.reminderDecisions, isEmpty);
    expect(alerts().single.time, DateTime(2026, 10, 23, 18));
  });

  test(
    'silencing a missed reminder keeps the to-do open without scheduling',
    () async {
      var w = await open();
      final n = await todo(w);
      await w.deleteNote(n.id);
      now = DateTime(2026, 10, 23, 8);
      await w.restoreNote(n.id);

      await w.decideRestoredReminder(n.id, 'buy', null);
      expect(w.reminderDecisions, isEmpty);
      await w.close();
      w = await open();
      expect(alerts(), isEmpty);
      expect(w.actionState(n.id, 'buy').completed, isFalse);
    },
  );

  test('deleting and restoring never touches a file shared with another note and keeps edits made elsewhere', () async {
    final w = await open();
    final shared = vault('images/shared.png');
    await shared.parent.create(recursive: true);
    await shared.writeAsBytes([1, 2, 3, 4]);
    final a = await w.captureText(title: '甲', text: '甲的内容');
    final b = await w.captureText(title: '乙', text: '乙的内容');
    final original = File('${root.path}/scan.pdf')..writeAsBytesSync([9, 9]);
    final attached = await w.attachFile(noteId: a.id, original: original);
    for (final name in ['甲', '乙']) {
      final f = vault('$name.md');
      await f.writeAsString(
        '${await f.readAsString()}\n![[images/shared.png]]\n',
      );
    }
    final edited = await vault('甲.md').readAsString();
    final other = await vault('乙.md').readAsString();

    await w.deleteNote(a.id);
    expect(await shared.readAsBytes(), [1, 2, 3, 4]);
    expect(await vault('乙.md').readAsString(), other);
    expect(
      File(w.attachments.firstWhere((x) => x.id == attached.id).sourcePath)
          .readAsBytesSync(),
      [9, 9],
    );

    await w.restoreNote(a.id);
    expect(await vault('甲.md').readAsString(), edited);
    expect(await shared.readAsBytes(), [1, 2, 3, 4]);
    expect(w.notes.map((n) => n.id).toSet(), {a.id, b.id});
  });

  test(
    'a deletion interrupted before the note file is removed finishes after restart',
    () async {
      var w = await open();
      final n = await todo(w);
      final vaultDir = Directory('${root.path}/vault');
      await Process.run('chmod', ['555', vaultDir.path]);
      addTearDown(() => Process.run('chmod', ['755', vaultDir.path]));

      await w.deleteNote(n.id);
      expect(w.notes, isEmpty);
      expect(alerts(), isEmpty);
      expect(vault('安排.md').existsSync(), isTrue);

      await w.close();
      await Process.run('chmod', ['755', vaultDir.path]);
      w = await open();
      expect(vault('安排.md').existsSync(), isFalse);
      expect(w.recycleBin.single.noteId, n.id);
      expect(alerts(), isEmpty);
    },
    skip: Platform.isWindows
        ? 'simulates an unwritable vault with POSIX chmod; the Dart retry logic is covered on macOS/Linux'
        : false,
  );

  test(
    'deleted notes leave associations and topic suggestions until restored',
    () async {
      final f = BudgetFixture();
      await f.start();
      addTearDown(f.close);
      final w = f.workspaces.first;
      final research = await w.captureText(title: '用户访谈', text: '新手障碍。');
      final source = await w.captureText(title: '观察记录', text: '不知道点哪里。');
      f.modelResult = {
        'manifestVersion': 3,
        'kind': 'ordinary',
        'title': '首次使用观察',
        'body': '不知道下一步如何操作。',
        'actions': [],
        'associations': [
          {'noteId': research.id, 'reason': '同为使用障碍。'},
        ],
        'newTopics': [
          {'title': '引导流程', 'reason': '改进线索。'},
        ],
      };
      await w.processTextNote(source.id);
      expect(w.pendingTopicSuggestions, hasLength(1));

      await w.deleteNote(research.id);
      expect(w.notes.single.associations, isEmpty);
      await w.deleteNote(source.id);
      expect(w.pendingTopicSuggestions, isEmpty);
      expect(w.pendingConfirmationItems, isEmpty);

      await w.restoreNote(research.id);
      await w.restoreNote(source.id);
      expect(
        w.notes.firstWhere((n) => n.id == source.id).associations.single.title,
        '用户访谈',
      );
      expect(w.pendingTopicSuggestions, hasLength(1));
    },
  );

  test(
    'a restore that cannot write yet is retried without creating a second copy',
    () async {
      var w = await open();
      final n = await todo(w);
      await vault('安排.md').writeAsString(
        '${await vault('安排.md').readAsString()}\n在 Obsidian 补充的一行\n',
      );
      final markdown = await vault('安排.md').readAsString();
      await w.deleteNote(n.id);
      final vaultDir = Directory('${root.path}/vault');
      await Process.run('chmod', ['555', vaultDir.path]);
      addTearDown(() => Process.run('chmod', ['755', vaultDir.path]));

      final pending = await w.restoreNote(n.id);
      expect(pending.status, NoteStatus.exportFailed);
      expect(w.recycleBin, isEmpty);

      await Process.run('chmod', ['755', vaultDir.path]);
      final saved = await w.retryNoteExport(n.id);
      expect(saved.status, NoteStatus.localSaved);
      expect(await vault('安排.md').readAsString(), markdown);
      await w.close();
      w = await open();
      expect(vault('安排 (2).md').existsSync(), isFalse);
      expect(w.notes.single.title, '安排');
      expect(await vault('安排.md').readAsString(), markdown);
      expect(alerts(), hasLength(1));
    },
    skip: Platform.isWindows
        ? 'simulates an unwritable vault with POSIX chmod; the Dart retry logic is covered on macOS/Linux'
        : false,
  );
}
