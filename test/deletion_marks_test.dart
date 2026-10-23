import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/note_workspace.dart';

import 'support/todo_sync_fixture.dart';

/// T26 deletion marks between two paired devices over a loopback Workerd +
/// D1. Note bodies are not transferred (ADR 0001); each device has its own
/// vault, so "an old copy" is the note a device still holds locally.
void main() {
  late TodoSyncFixture f;
  setUp(() async {
    f = TodoSyncFixture();
    await f.start();
    addTearDown(f.close);
  });

  File vault(int i, String relative) =>
      File('${f.root.path}/vault$i/$relative');

  test('a deletion moves the note into the paired device\'s recycle bin, and a later restore there brings it back once', () async {
    final a = f.workspaces[0], b = f.workspaces[1];
    final n = await f.todo(0);
    await f.todo(1);

    await a.deleteNote(n.id);
    expect(await a.syncTodos(), TaskStatusSync.synced);
    expect(await b.syncTodos(), TaskStatusSync.synced);
    expect(b.notes, isEmpty);
    expect(b.recycleBin.single.noteId, n.id);
    expect(f.alert(1, 'buy'), isNull);
    expect(b.todoSync.awaitingNote, isEmpty);
    // A duplicate pull changes nothing and queues nothing.
    await b.syncTodos();
    expect(b.recycleBin.single.noteId, n.id);
    expect(b.todoSync.pendingOperations, 0);

    f.now = DateTime(2026, 10, 21, 9);
    await b.restoreNote(n.id);
    await b.syncTodos();
    expect(await a.syncTodos(), TaskStatusSync.synced);
    expect(a.recycleBin, isEmpty);
    expect(a.notes.single.id, n.id);
    expect(a.notes.single.title, '安排');
    expect(a.notes.single.titleCollision, isFalse);
    expect(f.alert(0, 'buy')!.time, DateTime(2026, 10, 22, 10));
    await a.syncTodos();
    await b.syncTodos();
    expect(a.notes, hasLength(1));
    expect(b.notes, hasLength(1));
    expect(b.recycleBin, isEmpty);
  });

  test('a device offline with an old copy cannot bring back a note purged elsewhere, even after its own offline changes', () async {
    final a = f.workspaces[0];
    final n = await f.todo(0);
    await f.todo(1);
    await a.deleteNote(n.id);
    await a.purgeNotes([n.id]);
    expect(await a.syncTodos(), TaskStatusSync.synced);

    // Device B never heard of it and keeps working on its copy offline.
    f.offline = true;
    f.now = DateTime(2026, 10, 21, 9);
    await f.workspaces[1].completeAction(n.id, 'buy');
    await f.workspaces[1].snoozeReminder(n.id, 'call', minutes: 30);
    expect(await f.workspaces[1].syncTodos(), TaskStatusSync.offline);
    await f.reopen(1);
    f.offline = false;

    final b = f.workspaces[1];
    expect(await b.syncTodos(), TaskStatusSync.synced);
    expect(b.notes, isEmpty);
    expect(b.recycleBin, isEmpty);
    expect(f.alert(1, 'buy'), isNull);
    expect(f.alert(1, 'call'), isNull);
    expect(vault(1, '安排.md').existsSync(), isFalse);
    expect(
      vault(1, 'attachments/note-agent/${n.id}.txt').existsSync(),
      isFalse,
    );
    expect(b.todoSync.awaitingNote, isEmpty);

    // B's late operations reach device A without reviving anything.
    expect(await a.syncTodos(), TaskStatusSync.synced);
    expect(a.notes, isEmpty);
    expect(a.recycleBin, isEmpty);
    expect(a.todoSync.awaitingNote, isEmpty);
    expect(f.alert(0, 'buy'), isNull);
    await f.reopen(0);
    await f.reopen(1);
    expect(await f.workspaces[0].syncTodos(), TaskStatusSync.synced);
    expect(await f.workspaces[1].syncTodos(), TaskStatusSync.synced);
    expect(f.workspaces[0].notes, isEmpty);
    expect(f.workspaces[1].notes, isEmpty);
    expect(f.workspaces[1].recycleBin, isEmpty);
  });

  test(
    'a purge that arrives before its note still applies when the note arrives',
    () async {
      final a = f.workspaces[0];
      final n = await f.todo(0);
      await a.deleteNote(n.id);
      await a.purgeNotes([n.id]);
      await a.syncTodos();
      expect(await f.workspaces[1].syncTodos(), TaskStatusSync.synced);
      expect(f.workspaces[1].todoSync.awaitingNote, isEmpty);

      await f.todo(1); // The old copy arrives late on device B.
      final b = f.workspaces[1];
      await b.syncTodos();
      expect(b.notes, isEmpty);
      expect(b.recycleBin, isEmpty);
      expect(f.alert(1, 'buy'), isNull);
    },
  );

  test('a restore made offline before a later deletion elsewhere does not undo that deletion', () async {
    final n = await f.todo(0);
    await f.todo(1);
    f.offline = true;
    final b = f.workspaces[1];
    await b.deleteNote(n.id);
    f.now = DateTime(2026, 10, 21, 8, 1);
    await b.restoreNote(n.id);
    f.now = DateTime(2026, 10, 21, 8, 10);
    await f.workspaces[0].deleteNote(n.id);
    f.offline = false;

    await b.syncTodos();
    await f.workspaces[0].syncTodos();
    await b.syncTodos();
    for (final w in f.workspaces) {
      expect(w.notes, isEmpty);
      expect(w.recycleBin.single.noteId, n.id);
    }
    expect(f.alert(1, 'buy'), isNull);
  });
}
