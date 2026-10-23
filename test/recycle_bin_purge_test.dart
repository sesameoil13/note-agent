import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/note_workspace.dart';

import 'support/pending_notification_fixture.dart';

/// T26: bulk restore and 永久清除 through the NoteWorkspace seam, against a
/// real temporary vault and a fake notification port.
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
    root = await Directory.systemTemp.createTemp('recycle-purge-');
    await Directory('${root.path}/vault').create();
    port = PendingNotifications();
    now = DateTime(2026, 10, 21, 8);
    addTearDown(() => root.delete(recursive: true));
  });

  test('purging one note removes its retained copy and own files but keeps every file another note still references', () async {
    var w = await open();
    final a = await w.captureText(title: '甲', text: '甲的内容');
    final b = await w.captureText(title: '乙', text: '乙的内容');
    final c = await w.captureText(title: '丙', text: '丙的内容');
    final shared = await w.attachFile(
      noteId: a.id,
      original: File('${root.path}/shared.pdf')..writeAsBytesSync([1, 1]),
    );
    final own = await w.attachFile(
      noteId: a.id,
      original: File('${root.path}/own.pdf')..writeAsBytesSync([2, 2]),
    );
    final binned = await w.attachFile(
      noteId: a.id,
      original: File('${root.path}/binned.pdf')..writeAsBytesSync([3, 3]),
    );
    String rel(String path) => path.substring(path.indexOf('/vault/') + 7);
    final sharedPath = rel(shared.sourcePath),
        ownPath = rel(own.sourcePath),
        binnedPath = rel(binned.sourcePath);
    final userImage = vault('images/photo.png');
    await userImage.parent.create(recursive: true);
    await userImage.writeAsBytes([7]);
    // 乙 embeds one of 甲's attachments; 丙 (later in the 回收站) another.
    await vault('乙.md').writeAsString(
      '${await vault('乙.md').readAsString()}\n![[$sharedPath]]\n',
    );
    await vault('丙.md').writeAsString(
      '${await vault('丙.md').readAsString()}\n[附件]($binnedPath)\n',
    );
    await vault('甲.md').writeAsString(
      '${await vault('甲.md').readAsString()}\n![[images/photo.png]]\n',
    );
    await w.readVaultEdits();
    await w.deleteNote(a.id);
    await w.deleteNote(c.id);
    final otherNote = await vault('乙.md').readAsString();

    await w.purgeNotes([a.id]);

    expect(w.recycleBin.map((r) => r.noteId), [c.id]);
    expect(vault('attachments/note-agent/${a.id}.txt').existsSync(), isFalse);
    expect(vault(ownPath).existsSync(), isFalse);
    expect(vault(sharedPath).readAsBytesSync(), [1, 1]);
    expect(vault(binnedPath).readAsBytesSync(), [3, 3]);
    expect(userImage.readAsBytesSync(), [7]);
    expect(await vault('乙.md').readAsString(), otherNote);
    expect(vault('attachments/note-agent/${b.id}.txt').existsSync(), isTrue);
    expect(w.attachments.where((x) => x.noteId == a.id), isEmpty);
    await expectLater(w.restoreNote(a.id), throwsA(isA<StateError>()));

    await w.close();
    w = await open();
    expect(w.recycleBin.map((r) => r.noteId), [c.id]);
    expect(w.notes.map((n) => n.id), [b.id]);
    expect(vault('甲.md').existsSync(), isFalse);
  });

  test('a note outside the 回收站 cannot be purged', () async {
    final w = await open();
    final n = await w.captureText(title: '留着', text: '不要清除');
    await expectLater(w.purgeNotes([n.id]), throwsA(isA<StateError>()));
    expect(w.notes.single.id, n.id);
    expect(vault('留着.md').existsSync(), isTrue);
  });

  test('restoring everything at once keeps same-named notes apart, revives future reminders and holds missed ones', () async {
    final w = await open();
    final soon = await todo(w, time: '明天10:00');
    await w.deleteNote(soon.id);
    final later = await todo(w, time: '后天10:00');
    await w.deleteNote(later.id);
    final live = await w.captureText(title: '安排', text: '仍在使用的同名笔记');
    final liveMarkdown = await vault('安排.md').readAsString();

    now = DateTime(2026, 10, 22, 12);
    final restored = await w.restoreNotes(
      w.recycleBin.map((r) => r.noteId).toList(),
    );

    expect(restored.map((n) => n.id).toSet(), {soon.id, later.id});
    expect(w.recycleBin, isEmpty);
    expect(await vault('安排.md').readAsString(), liveMarkdown);
    expect(w.notes.firstWhere((n) => n.id == live.id).title, '安排');
    final titles = w.notes.map((n) => n.title).toSet();
    expect(titles, hasLength(3));
    expect(
      w.notes.where((n) => n.id != live.id).every((n) => n.titleCollision),
      isTrue,
    );
    expect(alerts().single.time, DateTime(2026, 10, 23, 10));
    expect(w.reminderDecisions.single.noteId, soon.id);
  });

  test(
    'purging everything empties the 回收站 and leaves nothing to decide or remind',
    () async {
      var w = await open();
      final one = await todo(w, title: '一');
      final two = await todo(w, title: '二');
      await w.deleteNote(one.id);
      await w.deleteNote(two.id);
      await w.purgeNotes(w.recycleBin.map((r) => r.noteId).toList());
      expect(w.recycleBin, isEmpty);
      expect(w.notes, isEmpty);
      expect(alerts(), isEmpty);
      now = DateTime(2026, 10, 25);
      await w.close();
      w = await open();
      expect(w.recycleBin, isEmpty);
      expect(w.reminderDecisions, isEmpty);
      expect(w.reminders, isEmpty);
      expect(alerts(), isEmpty);
      expect(w.todoSync.awaitingNote, isEmpty);
    },
  );
}
