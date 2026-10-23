import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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

  NotificationRequest alert(String actionId) => port.pending.values
      .where(
        (r) =>
            r.payload['kind'] == 'actionReminder' &&
            r.payload['actionId'] == actionId,
      )
      .single;

  void respond(NotificationRequest r, String action) => port.interactions.add(
    NotificationInteraction(
      id: r.id,
      payload: r.payload,
      actionIdentifier: action,
    ),
  );

  Future<String> noteFile(NoteWorkspace w, WorkspaceNote n) =>
      File(w.notes.firstWhere((x) => x.id == n.id).notePath).readAsString();

  setUp(() async {
    root = await Directory.systemTemp.createTemp('reminder-lifecycle-');
    await Directory('${root.path}/vault').create();
    port = PendingNotifications();
    now = DateTime(2026, 10, 21, 8);
    addTearDown(() => root.delete(recursive: true));
  });

  test('completing from a notification cancels the plan, checks the note and survives restart; late snoozes are ignored', () async {
    var w = await open();
    final n = await todo(w);
    final shown = alert('buy');
    expect(shown.payload['lifecycle'], '1');
    expect(shown.payload['vault'], isNotEmpty);

    respond(shown, 'complete');
    respond(shown, 'complete');
    expect(await w.takeReminderInteractions(), isNull);
    expect(w.actionState(n.id, 'buy').completed, true);
    expect(w.actionState(n.id, 'buy').notePending, false);
    expect(w.reminders.map((r) => r.actionId), ['call']);
    expect(
      port.pending.values.where((r) => r.payload['actionId'] == 'buy'),
      isEmpty,
    );
    expect(await noteFile(w, n), contains('- [x] 买电池\n- [ ] 联系物业'));

    // A snooze from the same delivery arriving after completion never revives it.
    respond(shown, 'snooze');
    await w.takeReminderInteractions();
    expect(w.reminders.map((r) => r.actionId), ['call']);
    await expectLater(w.snoozeReminder(n.id, 'buy'), throwsStateError);

    await w.close();
    w = await open();
    expect(w.actionState(n.id, 'buy').completed, true);
    expect(w.reminders.map((r) => r.actionId), ['call']);
  });

  test('snooze defaults to thirty minutes, can be changed, and a duplicate delivery shifts only once', () async {
    final w = await open();
    final n = await todo(w);
    now = DateTime(2026, 10, 22, 10, 5);
    final shown = alert('buy');
    respond(shown, 'snooze');
    respond(shown, 'snooze');
    await w.takeReminderInteractions();
    final snoozed = w.reminders.firstWhere((r) => r.actionId == 'buy');
    expect(snoozed.time, DateTime(2026, 10, 22, 10, 35));
    expect(snoozed.snoozed, true);
    expect(snoozed.status, ReminderStatus.scheduled);
    expect(port.pending.containsKey(shown.id), false);
    expect(alert('buy').time, DateTime(2026, 10, 22, 10, 35));

    await w.snoozeReminder(n.id, 'buy', minutes: 90);
    expect(alert('buy').time, DateTime(2026, 10, 22, 11, 35));

    await w.setReminderDefaults(const ReminderDefaults(snoozeMinutes: 10));
    expect(w.reminderDefaults.snoozeMinutes, 10);
    respond(alert('call'), 'snooze');
    await w.takeReminderInteractions();
    expect(alert('call').time, DateTime(2026, 10, 22, 10, 15));
    // A snoozed default plan is not moved by a later defaults preview.
    expect(w.previewReminderDefaults().changes, isEmpty);
    await expectLater(
      w.setReminderDefaults(const ReminderDefaults(snoozeMinutes: 0)),
      throwsArgumentError,
    );
  });

  test('explicit reopen starts a new lifecycle that stale completions cannot close', () async {
    final w = await open();
    final n = await todo(w);
    final first = alert('buy');
    await w.completeAction(n.id, 'buy');
    await expectLater(
      w.setActionReminderTime(n.id, 'buy', DateTime(2026, 10, 23, 9)),
      throwsStateError,
    );

    await w.reopenAction(n.id, 'buy', DateTime(2026, 10, 25, 15, 30));
    final state = w.actionState(n.id, 'buy');
    expect(
      (state.lifecycle, state.completed, state.notePending),
      (2, false, false),
    );
    final reopened = alert('buy');
    expect(reopened.time, DateTime(2026, 10, 25, 15, 30));
    expect(reopened.payload['lifecycle'], '2');
    expect(reopened.id, isNot(first.id));
    expect(await noteFile(w, n), contains('- [ ] 买电池'));

    // The old lifecycle's notification is stale in both directions.
    respond(first, 'complete');
    respond(first, 'snooze');
    await w.takeReminderInteractions();
    expect(w.actionState(n.id, 'buy').completed, false);
    expect(alert('buy').time, DateTime(2026, 10, 25, 15, 30));

    // A later explicit time replaces the reopen time.
    await w.setActionReminderTime(n.id, 'buy', DateTime(2026, 10, 26, 8));
    expect(alert('buy').time, DateTime(2026, 10, 26, 8));

    respond(alert('buy'), 'complete');
    await w.takeReminderInteractions();
    expect(w.actionState(n.id, 'buy').completed, true);
    await expectLater(
      w.reopenAction(n.id, 'call', DateTime(2026, 10, 30)),
      throwsStateError,
    );
  });

  test('removing a mis-extracted action cancels its plan and its notification becomes inert', () async {
    final w = await open();
    final n = await todo(w);
    final shown = alert('call');
    await w.resolveNoteActions(
      n.id,
      kind: NoteKind.todo,
      actions: [w.notes.single.actions.firstWhere((a) => a.id == 'buy')],
    );
    expect(w.reminders.map((r) => r.actionId), ['buy']);
    expect(port.pending.containsKey(shown.id), false);
    respond(shown, 'complete');
    respond(shown, 'snooze');
    await w.takeReminderInteractions();
    expect(w.reminders.map((r) => r.actionId), ['buy']);
    expect(await noteFile(w, n), isNot(contains('- [ ] 联系物业')));
  });

  test('edits keep completion, and an externally edited note keeps the durable completion pending', () async {
    final w = await open();
    final n = await todo(w);
    await w.completeAction(n.id, 'call');
    final kept = w.notes.single.actions;
    await w.resolveNoteActions(
      n.id,
      kind: NoteKind.todo,
      actions: [
        for (final a in kept)
          WorkspaceAction(
            id: a.id,
            text: a.id == 'call' ? '联系物业维修' : a.text,
            decision: a.decision,
            reason: a.reason,
            timeExpression: a.timeExpression,
            timeStatus: a.timeStatus,
          ),
      ],
    );
    expect(await noteFile(w, n), contains('- [x] 联系物业维修'));
    expect(w.actionState(n.id, 'call').completed, true);

    final file = File(w.notes.single.notePath);
    await file.writeAsString(
      (await file.readAsString()).replaceFirst('## 摘要', '## 摘要\n\n手动补充'),
    );
    respond(alert('buy'), 'complete');
    await w.takeReminderInteractions();
    expect(w.actionState(n.id, 'buy').completed, true);
    expect(w.actionState(n.id, 'buy').notePending, true);
    expect(w.reminders, isEmpty);
    expect(await file.readAsString(), contains('- [ ] 买电池'));
  });

  test('tapping an alert opens its note without changing the plan', () async {
    final w = await open();
    final n = await todo(w);
    final shown = alert('buy');
    respond(shown, 'default');
    expect(await w.takeReminderInteractions(), n.id);
    expect(alert('buy').id, shown.id);
    expect(w.actionState(n.id, 'buy').completed, false);
  });
}
