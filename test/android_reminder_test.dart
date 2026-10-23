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
    final n = await w.captureText(title: '安排', text: '明天十点买电池。');
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
      ],
    );
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('android-reminder-');
    await Directory('${root.path}/vault').create();
    port = PendingNotifications();
    now = DateTime(2026, 10, 21, 8);
    addTearDown(() => root.delete(recursive: true));
  });

  test('without exact alarms reminders are still scheduled but reported as possibly late', () async {
    port.exactTiming = false;
    final w = await open();
    await todo(w);
    expect(w.reminders.single.status, ReminderStatus.scheduled);
    expect(w.notificationTimingExact, isFalse);
    port.exactTiming = true;
    await w.reconcileReminders();
    expect(w.notificationTimingExact, isTrue);
  });
  test('alarms the OS dropped (reboot or force stop) are scheduled again on the next check under the same id', () async {
    final w = await open();
    await todo(w);
    final id = w.reminders.single.id;
    port.pending.clear();
    port.accepted.clear();
    await w.reconcileReminders();
    expect(port.pending.keys, [id]);
    expect(w.reminders.single.status, ReminderStatus.scheduled);
  });
  test('alerts carry the configured snooze length so a closed App can still postpone natively', () async {
    final w = await open();
    await todo(w);
    expect(port.pending.values.single.payload['snoozeMinutes'], '30');
    await w.setReminderDefaults(const ReminderDefaults(snoozeMinutes: 45));
    await w.snoozeReminder(w.reminders.single.noteId, 'buy');
    expect(port.pending.values.single.payload['snoozeMinutes'], '45');
  });
  test('a snooze the phone already re-armed while the App was closed is adopted without a second alarm', () async {
    var w = await open();
    await todo(w);
    final shown = port.pending.values.single;
    await w.close();
    now = DateTime(2026, 10, 22, 10);
    final until = now.add(const Duration(minutes: 30));
    // Native receiver: recorded durably and re-armed under the same id.
    port.pending[shown.id] = NotificationRequest(
      id: shown.id,
      title: shown.title,
      body: shown.body,
      time: until,
      payload: shown.payload,
    );
    port.interactions.add(
      NotificationInteraction(
        id: shown.id,
        actionIdentifier: 'snooze',
        payload: {
          ...shown.payload,
          'snoozedUntilMs': '${until.millisecondsSinceEpoch}',
        },
      ),
    );
    now = DateTime(2026, 10, 22, 12);
    final schedules = port.schedules;
    w = await open();
    await w.takeReminderInteractions();
    final r = w.reminders.single;
    expect(r.id, shown.id);
    expect(r.time, until);
    expect(r.snoozed, isTrue);
    expect(port.schedules, schedules);
    expect(port.pending.keys, [shown.id]);
  });
}
