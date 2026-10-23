import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/note_workspace.dart';

import 'support/todo_sync_fixture.dart';

void main() {
  late TodoSyncFixture f;
  setUp(() async {
    f = TodoSyncFixture();
    await f.start();
    addTearDown(f.close);
  });

  test('completing on one device cancels the reminder on the paired device after both sync', () async {
    final a = f.workspaces[0], b = f.workspaces[1];
    final n = await f.todo(0);
    await f.todo(1);
    expect(f.alert(1, 'buy'), isNotNull);

    await a.completeAction(n.id, 'buy');
    expect(a.todoSync.pendingOperations, 1);
    expect(await a.syncTodos(), TaskStatusSync.synced);
    expect(a.todoSync.pendingOperations, 0);

    expect(await b.syncTodos(), TaskStatusSync.synced);
    expect(b.actionState(n.id, 'buy').completed, isTrue);
    expect(f.alert(1, 'buy'), isNull);
    expect(f.alert(1, 'call'), isNotNull);
    expect(b.reminders.map((r) => r.actionId), ['call']);
    // Pulling the same state again changes nothing.
    await b.syncTodos();
    expect(b.actionState(n.id, 'buy').completed, isTrue);
    expect(b.todoSync.pendingOperations, 0);
  });

  test('offline operations survive restart and completion beats a later snooze whatever order they arrive in', () async {
    final n = await f.todo(0);
    await f.todo(1);
    f.offline = true;
    f.now = DateTime(2026, 10, 22, 10, 1);
    await f.workspaces[0].completeAction(n.id, 'buy');
    // Device B snoozes afterwards by its own clock, while also offline.
    f.now = DateTime(2026, 10, 22, 10, 5);
    await f.workspaces[1].snoozeReminder(n.id, 'buy', minutes: 60);
    expect(f.alert(1, 'buy')!.time, DateTime(2026, 10, 22, 11, 5));
    expect(await f.workspaces[0].syncTodos(), TaskStatusSync.offline);
    expect(await f.workspaces[1].syncTodos(), TaskStatusSync.offline);
    expect(f.workspaces[1].todoSync.pendingOperations, 1);
    expect(f.workspaces[1].todoSync.message, contains('保留在本机'));
    await f.reopen(0);
    await f.reopen(1);
    expect(f.workspaces[0].todoSync.status, TaskStatusSync.offline);
    expect(f.workspaces[0].todoSync.pendingOperations, 1);

    f.offline = false;
    // The late snooze reaches the endpoint first.
    expect(await f.workspaces[1].syncTodos(), TaskStatusSync.synced);
    expect(await f.workspaces[0].syncTodos(), TaskStatusSync.synced);
    expect(await f.workspaces[1].syncTodos(), TaskStatusSync.synced);
    for (var i = 0; i < 2; i++) {
      final w = f.workspaces[i];
      expect(w.actionState(n.id, 'buy').completed, isTrue, reason: '$i');
      expect(f.alert(i, 'buy'), isNull, reason: '$i');
      expect(w.reminders.map((r) => r.actionId), ['call']);
      expect(w.todoSync.pendingOperations, 0);
    }
    expect(
      await File(f.workspaces[1].notes.single.notePath).readAsString(),
      contains('- [x] 买电池'),
    );
  });

  test('reopen on one device starts a new lifecycle on the other; stale alerts from the old one stay ignored', () async {
    final n = await f.todo(0);
    await f.todo(1);
    final oldAlert = f.alert(0, 'buy')!;
    await f.workspaces[1].completeAction(n.id, 'buy');
    await f.workspaces[1].syncTodos();
    await f.workspaces[0].syncTodos();
    expect(f.workspaces[0].actionState(n.id, 'buy').completed, isTrue);

    final again = DateTime(2026, 10, 23, 15);
    await f.workspaces[1].reopenAction(n.id, 'buy', again);
    await f.workspaces[1].syncTodos();
    await f.workspaces[0].syncTodos();
    final a = f.workspaces[0];
    expect(a.actionState(n.id, 'buy').completed, isFalse);
    expect(a.actionState(n.id, 'buy').lifecycle, 2);
    expect(f.alert(0, 'buy')!.time, again);
    expect(f.alert(0, 'buy')!.payload['lifecycle'], '2');
    expect(
      await File(a.notes.single.notePath).readAsString(),
      contains('- [ ] 买电池'),
    );

    // The first lifecycle's completion button, pressed late on device A.
    f.ports[0].interactions.add(
      NotificationInteraction(
        id: oldAlert.id,
        payload: oldAlert.payload,
        actionIdentifier: 'complete',
      ),
    );
    await a.takeReminderInteractions();
    await a.syncTodos();
    await f.workspaces[1].syncTodos();
    expect(f.workspaces[1].actionState(n.id, 'buy').completed, isFalse);
    expect(f.alert(1, 'buy')!.time, again);
  });

  test(
    'a snooze chosen on one device moves the same reminder on the other',
    () async {
      final n = await f.todo(0);
      await f.todo(1);
      f.now = DateTime(2026, 10, 22, 10, 5);
      await f.workspaces[0].snoozeReminder(n.id, 'buy', minutes: 120);
      await f.workspaces[0].syncTodos();
      await f.workspaces[1].syncTodos();
      expect(f.alert(1, 'buy')!.time, DateTime(2026, 10, 22, 12, 5));
      final moved = f.workspaces[1].reminders.firstWhere(
        (r) => r.actionId == 'buy',
      );
      expect(moved.snoozed, isTrue);
      // Applying it again (e.g. a duplicate pull) does not shift it twice.
      await f.workspaces[1].syncTodos();
      await f.workspaces[1].reconcileReminders();
      expect(f.alert(1, 'buy')!.id, moved.id);
      expect(f.alert(0, 'buy')!.time, DateTime(2026, 10, 22, 12, 5));
    },
  );

  test('a state that arrives before its note is reported honestly and applied when the note arrives', () async {
    final n = await f.todo(0);
    await f.workspaces[0].completeAction(n.id, 'buy');
    await f.workspaces[0].syncTodos();
    final b = f.workspaces[1];
    expect(await b.syncTodos(), TaskStatusSync.synced);
    expect(b.notes, isEmpty);
    final waiting = b.todoSync.awaitingNote.single;
    expect(waiting.noteId, n.id);
    expect(waiting.actionId, 'buy');
    expect(waiting.completed, isTrue);
    await f.reopen(1);
    expect(f.workspaces[1].todoSync.awaitingNote.single.actionId, 'buy');

    // The note body arrives later (here: the same note on device B).
    await f.todo(1);
    final arrived = f.workspaces[1];
    expect(arrived.todoSync.awaitingNote, isEmpty);
    expect(arrived.actionState(n.id, 'buy').completed, isTrue);
    expect(f.alert(1, 'buy'), isNull);
    expect(f.alert(1, 'call'), isNotNull);
  });

  test('removing an action cancels it on the paired device and later operations cannot revive it', () async {
    final n = await f.todo(0);
    await f.todo(1);
    await f.workspaces[0].resolveNoteActions(
      n.id,
      kind: NoteKind.todo,
      actions: [f.workspaces[0].notes.single.actions.first],
    );
    await f.workspaces[0].syncTodos();
    // Device B, before hearing of the removal, snoozes the removed action.
    f.now = DateTime(2026, 10, 22, 10, 5);
    await f.workspaces[1].snoozeReminder(n.id, 'call');
    await f.workspaces[1].syncTodos();
    await f.workspaces[1].syncTodos();
    expect(f.workspaces[1].actionState(n.id, 'call').removed, isTrue);
    expect(f.alert(1, 'call'), isNull);
    expect(f.alert(1, 'buy'), isNotNull);
    await f.workspaces[0].syncTodos();
    expect(f.alert(0, 'call'), isNull);
    expect(f.workspaces[0].todoSync.awaitingNote, isEmpty);
  });

  test('a reminder missed in the recycle bin keeps waiting for a decision through a paired snooze, and a paired completion settles it', () async {
    final n = await f.todo(0);
    await f.todo(1);
    final b = f.workspaces[1];
    await b.deleteNote(n.id);
    f.now = DateTime(2026, 10, 22, 10, 5);
    await b.restoreNote(n.id);
    expect(b.reminderDecisions.map((d) => d.actionId), contains('buy'));

    await f.workspaces[0].snoozeReminder(n.id, 'buy', minutes: 60);
    await f.workspaces[0].syncTodos();
    expect(await b.syncTodos(), TaskStatusSync.synced);
    expect(b.reminderDecisions.map((d) => d.actionId), contains('buy'));
    expect(f.alert(1, 'buy'), isNull);

    await f.workspaces[0].completeAction(n.id, 'buy');
    await f.workspaces[0].syncTodos();
    expect(await b.syncTodos(), TaskStatusSync.synced);
    expect(b.actionState(n.id, 'buy').completed, isTrue);
    expect(b.reminderDecisions.map((d) => d.actionId), isNot(contains('buy')));
    expect(f.alert(1, 'buy'), isNull);
  });

  test('a tick or a deleted line read from Obsidian syncs to the paired device like an App action', () async {
    final a = f.workspaces[0], b = f.workspaces[1];
    final n = await f.todo(0);
    await f.todo(1);
    final file = File(a.notes.single.notePath);
    await file.writeAsString(
      (await file.readAsString())
          .replaceFirst('- [ ] 买电池', '- [x] 买电池')
          .replaceFirst('- [ ] 联系物业\n', ''),
    );
    await file.setLastModified(DateTime(2026, 10, 21, 9));
    expect(await a.readVaultEdits(), [n.id]);
    expect(a.todoSync.pendingOperations, 2);
    expect(await a.syncTodos(), TaskStatusSync.synced);

    expect(await b.syncTodos(), TaskStatusSync.synced);
    expect(b.actionState(n.id, 'buy').completed, isTrue);
    expect(b.actionState(n.id, 'call').removed, isTrue);
    expect(f.alert(1, 'buy'), isNull);
    expect(f.alert(1, 'call'), isNull);
  });
}
