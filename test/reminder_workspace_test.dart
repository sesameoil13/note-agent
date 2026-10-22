import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/note_workspace.dart';

void main() {
  test('confirmed actions use calendar defaults while uncertain actions stay gated', () async {
    final root = await Directory.systemTemp.createTemp('reminder-workspace-');
    final notifications = _Notifications();
    final w = await NoteWorkspace.open(
      localDirectory: Directory('${root.path}/local'),
      vaultDirectory: await Directory('${root.path}/vault').create(),
      clock: () => DateTime(2026, 10, 21, 8),
      notifications: notifications,
    );
    addTearDown(() async {
      await w.close();
      await root.delete(recursive: true);
    });
    final n = await w.captureText(title: '安排', text: '安排采购和联系。');
    await w.resolveNoteActions(
      n.id,
      kind: NoteKind.todo,
      actions: [
        const WorkspaceAction(
          id: 'buy',
          text: '采购',
          decision: ActionDecision.confirmed,
        ),
        const WorkspaceAction(id: 'ask', text: '联系'),
      ],
    );
    expect(w.reminders.single.actionId, 'buy');
    expect(w.reminders.single.time, DateTime(2026, 10, 22, 9));
    expect(w.reminders.single.status, ReminderStatus.scheduled);
    expect(notifications.pending.values.single.time, DateTime(2026, 10, 22, 9));
  });
  test('explicit calendar expressions, periods and late processing use the collection date', () async {
    final root = await Directory.systemTemp.createTemp('reminder-calendar-');
    var now = DateTime(2026, 10, 21, 8);
    final port = _Notifications();
    final w = await NoteWorkspace.open(
      localDirectory: Directory('${root.path}/local'),
      vaultDirectory: await Directory('${root.path}/vault').create(),
      clock: () => now,
      notifications: port,
    );
    addTearDown(() async {
      await w.close();
      await root.delete(recursive: true);
    });
    final n = await w.captureText(title: '日程', text: '记录日程');
    now = DateTime(2026, 10, 24, 16);
    final expressions = [
      '2026-10-25 10:30',
      '2026-10-25',
      '明天上午',
      '后天下午',
      '今天晚上',
      'tomorrow morning',
      '2026-02-30',
      '某天',
    ];
    await w.resolveNoteActions(
      n.id,
      kind: NoteKind.todo,
      actions: [
        for (var i = 0; i < expressions.length; i++)
          WorkspaceAction(
            id: 'a$i',
            text: expressions[i],
            decision: ActionDecision.confirmed,
            timeStatus: ActionTimeStatus.explicit,
            timeExpression: expressions[i],
          ),
        const WorkspaceAction(
          id: 'unknown',
          text: '时间待定',
          decision: ActionDecision.confirmed,
          timeStatus: ActionTimeStatus.unresolved,
          timeExpression: '再决定',
        ),
      ],
    );
    final times = {for (final r in w.reminders) r.actionId: r.time};
    expect(times, {
      'a0': DateTime(2026, 10, 25, 10, 30),
      'a1': DateTime(2026, 10, 25, 9),
      'a2': DateTime(2026, 10, 22, 9),
      'a3': DateTime(2026, 10, 23, 14),
      'a4': DateTime(2026, 10, 21, 20),
      'a5': DateTime(2026, 10, 22, 9),
      'a6': DateTime(2026, 10, 22, 9),
      'a7': DateTime(2026, 10, 22, 9),
      'unknown': DateTime(2026, 10, 22, 9),
    });
    expect(w.reminders.where((r) => r.immediate).length, 7);
    expect(
      w.reminders.where((r) => r.timeNeedsConfirmation).map((r) => r.actionId),
      ['a6', 'a7', 'unknown'],
    );
  });

  test('common Mandarin clock expressions retain the stated hour rather than silently using nine', () async {
    final root = await Directory.systemTemp.createTemp('reminder-mandarin-');
    final port = _Notifications();
    final w = await NoteWorkspace.open(
      localDirectory: Directory('${root.path}/local'),
      vaultDirectory: await Directory('${root.path}/vault').create(),
      notifications: port,
      clock: () => DateTime(2026, 10, 21, 8),
    );
    addTearDown(() async {
      await w.close();
      await root.delete(recursive: true);
    });
    final n = await w.captureText(title: '中文时间', text: '记录');
    final samples = [
      '明早',
      '明晚',
      '明天上午十点半',
      '后天下午三点一刻',
      '明天早上十点零五分',
      '今天晚上八点三刻',
    ];
    await w.resolveNoteActions(
      n.id,
      kind: NoteKind.todo,
      actions: [
        for (var i = 0; i < samples.length; i++)
          WorkspaceAction(
            id: 'a$i',
            text: '事项$i',
            decision: ActionDecision.confirmed,
            timeStatus: ActionTimeStatus.explicit,
            timeExpression: samples[i],
          ),
      ],
    );
    expect(
      {for (final r in w.reminders) r.actionId: r.time},
      {
        'a0': DateTime(2026, 10, 22, 9),
        'a1': DateTime(2026, 10, 22, 20),
        'a2': DateTime(2026, 10, 22, 10, 30),
        'a3': DateTime(2026, 10, 23, 15, 15),
        'a4': DateTime(2026, 10, 22, 10, 5),
        'a5': DateTime(2026, 10, 21, 20, 45),
      },
    );
    expect(w.reminders.any((r) => r.timeNeedsConfirmation), false);
  });

  test('new defaults preserve existing plans until a confirmed preview and never override exact times', () async {
    final root = await Directory.systemTemp.createTemp('reminder-defaults-');
    final port = _Notifications();
    final w = await NoteWorkspace.open(
      localDirectory: Directory('${root.path}/local'),
      vaultDirectory: await Directory('${root.path}/vault').create(),
      clock: () => DateTime(2026, 10, 21, 8),
      notifications: port,
    );
    addTearDown(() async {
      await w.close();
      await root.delete(recursive: true);
    });
    final n = await w.captureText(title: '默认设置', text: '记录');
    await w.resolveNoteActions(
      n.id,
      kind: NoteKind.todo,
      actions: [
        const WorkspaceAction(
          id: 'default',
          text: '默认',
          decision: ActionDecision.confirmed,
        ),
        const WorkspaceAction(
          id: 'exact',
          text: '准确',
          decision: ActionDecision.confirmed,
          timeStatus: ActionTimeStatus.explicit,
          timeExpression: '2026-10-25 12:00',
        ),
      ],
    );
    final original = w.reminders.firstWhere((r) => r.actionId == 'default');
    await w.setReminderDefaults(const ReminderDefaults(tomorrowMinute: 600));
    expect(
      w.reminders.firstWhere((r) => r.actionId == 'default').time,
      DateTime(2026, 10, 22, 9),
    );
    final preview = w.previewReminderDefaults();
    expect(preview.changes.single.actionId, 'default');
    expect(preview.changes.single.time, DateTime(2026, 10, 22, 10));
    await w.applyReminderDefaults(preview);
    expect(
      w.reminders.firstWhere((r) => r.actionId == 'default').time,
      DateTime(2026, 10, 22, 10),
    );
    expect(port.pending.containsKey(original.id), isFalse);
    expect(
      w.reminders.firstWhere((r) => r.actionId == 'exact').time,
      DateTime(2026, 10, 25, 12),
    );
    final next = await w.captureText(title: '新增', text: '新增');
    await w.resolveNoteActions(
      next.id,
      kind: NoteKind.todo,
      actions: [
        const WorkspaceAction(
          id: 'new',
          text: '新增',
          decision: ActionDecision.confirmed,
        ),
      ],
    );
    expect(
      w.reminders.firstWhere((r) => r.actionId == 'new').time,
      DateTime(2026, 10, 22, 10),
    );
    await w.setActionReminderTime(n.id, 'default', DateTime(2026, 10, 28, 17));
    expect(
      w.reminders.firstWhere((r) => r.actionId == 'default').explicitTime,
      isTrue,
    );
    await w.setReminderDefaults(const ReminderDefaults(tomorrowMinute: 660));
    final stale = w.previewReminderDefaults();
    await w.setActionReminderTime(next.id, 'new', DateTime(2026, 10, 29, 18));
    await expectLater(w.applyReminderDefaults(stale), throwsStateError);
    expect(w.previewReminderDefaults().changes, isEmpty);
  });

  test(
    'a locally confirmed exact time replaces the OS plan and survives restart',
    () async {
      final root = await Directory.systemTemp.createTemp('reminder-replace-');
      final port = _Notifications();
      final local = Directory('${root.path}/local');
      final vault = await Directory('${root.path}/vault').create();
      var w = await NoteWorkspace.open(
        localDirectory: local,
        vaultDirectory: vault,
        notifications: port,
        clock: () => DateTime(2026, 10, 21, 8),
      );
      addTearDown(() async {
        await w.close();
        await root.delete(recursive: true);
      });
      final n = await w.captureText(title: '明确时间', text: '采购');
      await w.resolveNoteActions(
        n.id,
        kind: NoteKind.todo,
        actions: [
          const WorkspaceAction(
            id: 'buy',
            text: '采购',
            decision: ActionDecision.confirmed,
          ),
        ],
      );
      await w.setActionReminderTime(
        n.id,
        'buy',
        DateTime(2026, 10, 27, 16, 45),
      );
      expect(w.reminders.single.time, DateTime(2026, 10, 27, 16, 45));
      expect(port.pending.values.single.time, DateTime(2026, 10, 27, 16, 45));
      final id = w.reminders.single.id;
      await w.close();
      w = await NoteWorkspace.open(
        localDirectory: local,
        vaultDirectory: vault,
        notifications: port,
        clock: () => DateTime(2026, 10, 21, 8),
      );
      expect(w.reminders.single.id, id);
      expect(port.pending.length, 1);
      expect(port.requested, false);
    },
  );

  test('correcting action text replaces the pending body without changing its retained default time', () async {
    final root = await Directory.systemTemp.createTemp('reminder-correction-');
    final port = _Notifications();
    final w = await NoteWorkspace.open(
      localDirectory: Directory('${root.path}/local'),
      vaultDirectory: await Directory('${root.path}/vault').create(),
      notifications: port,
      clock: () => DateTime(2026, 10, 21, 8),
    );
    addTearDown(() async {
      await w.close();
      await root.delete(recursive: true);
    });
    final n = await w.captureText(title: '采购', text: '买电池');
    await w.resolveNoteActions(
      n.id,
      kind: NoteKind.todo,
      actions: [
        const WorkspaceAction(
          id: 'buy',
          text: '买电池',
          decision: ActionDecision.confirmed,
        ),
      ],
    );
    await w.setReminderDefaults(const ReminderDefaults(tomorrowMinute: 720));
    await w.resolveNoteActions(
      n.id,
      kind: NoteKind.todo,
      actions: [
        const WorkspaceAction(
          id: 'buy',
          text: '买充电电池',
          decision: ActionDecision.confirmed,
        ),
      ],
    );
    expect(w.reminders.single.time, DateTime(2026, 10, 22, 9));
    expect(port.pending.values.single.body, '买充电电池');
    expect(port.pending.values.single.time, DateTime(2026, 10, 22, 9));
  });

  test('permission is requested only on demand and OS failure preserves a retryable plan', () async {
    final root = await Directory.systemTemp.createTemp('reminder-permission-');
    final port = _Notifications()..permission = NotificationPermission.denied;
    final local = Directory('${root.path}/local');
    final vault = await Directory('${root.path}/vault').create();
    var w = await NoteWorkspace.open(
      localDirectory: local,
      vaultDirectory: vault,
      notifications: port,
      clock: () => DateTime(2026, 10, 21, 8),
    );
    addTearDown(() async {
      await w.close();
      await root.delete(recursive: true);
    });
    final n = await w.captureText(title: '权限', text: '记录');
    await w.resolveNoteActions(
      n.id,
      kind: NoteKind.todo,
      actions: [
        const WorkspaceAction(
          id: 'buy',
          text: '采购',
          decision: ActionDecision.confirmed,
        ),
      ],
    );
    expect(port.requested, false);
    expect(port.pending, isEmpty);
    expect(w.reminders.single.status, ReminderStatus.blocked);
    port.failSchedule = true;
    await w.requestNotificationPermission();
    expect(port.requested, true);
    expect(w.reminders.single.status, ReminderStatus.failed);
    expect(w.notes.single.actions.single.actionConfirmed, true);
    await w.close();
    port.failSchedule = false;
    w = await NoteWorkspace.open(
      localDirectory: local,
      vaultDirectory: vault,
      notifications: port,
      clock: () => DateTime(2026, 10, 21, 8),
    );
    expect(w.reminders.single.status, ReminderStatus.scheduled);
    expect(port.pending.length, 1);
    port.failCancel = true;
    await w.resolveNoteActions(n.id, kind: NoteKind.ordinary, actions: []);
    expect(w.reminders, isEmpty);
    expect(w.notificationError, isNotNull);
    expect(port.pending.length, 1);
    port.failCancel = false;
    await w.reconcileReminders();
    expect(port.pending, isEmpty);
    expect(w.notificationError, isNull);
  });

  test(
    'late plans alert once and unknown inspection never authorizes a new alert',
    () async {
      final root = await Directory.systemTemp.createTemp('reminder-once-');
      final port = _Notifications();
      final local = Directory('${root.path}/local');
      final vault = await Directory('${root.path}/vault').create();
      var now = DateTime(2026, 10, 21, 8);
      var w = await NoteWorkspace.open(
        localDirectory: local,
        vaultDirectory: vault,
        notifications: port,
        clock: () => now,
      );
      addTearDown(() async {
        await w.close();
        await root.delete(recursive: true);
      });
      final n = await w.captureText(title: '延期处理', text: '记录');
      now = DateTime(2026, 10, 24, 8);
      port.failInspect = true;
      await w.resolveNoteActions(
        n.id,
        kind: NoteKind.todo,
        actions: [
          const WorkspaceAction(
            id: 'buy',
            text: '采购',
            decision: ActionDecision.confirmed,
          ),
        ],
      );
      expect(w.notificationPermission, NotificationPermission.unknown);
      expect(port.pending, isEmpty);
      port.failInspect = false;
      await w.reconcileReminders();
      expect(port.scheduled, 1);
      expect(port.pending.values.single.immediate, true);
      port.pending.clear();
      port.accepted.clear();
      await w.close();
      w = await NoteWorkspace.open(
        localDirectory: local,
        vaultDirectory: vault,
        notifications: port,
        clock: () => now,
      );
      await w.reconcileReminders();
      expect(w.reminders.single.status, ReminderStatus.elapsed);
      expect(port.scheduled, 1);
    },
  );
}

class _Notifications implements NotificationPort {
  bool requested = false,
      failSchedule = false,
      failCancel = false,
      failInspect = false;
  int scheduled = 0;
  NotificationPermission permission = NotificationPermission.allowed;
  final pending = <String, NotificationRequest>{};
  final accepted = <String>{};
  @override
  Future<NotificationSnapshot> inspect() async {
    if (failInspect) throw StateError("controlled inspect failure");
    return NotificationSnapshot(
      permission: permission,
      pendingIds: pending.keys.toSet(),
      acceptedIds: accepted,
    );
  }

  @override
  Future<NotificationPermission> requestPermission() async {
    requested = true;
    permission = NotificationPermission.allowed;
    return permission;
  }

  @override
  Future<void> schedule(NotificationRequest request) async {
    if (failSchedule) throw StateError("controlled schedule failure");
    scheduled++;
    pending[request.id] = request;
    accepted.add(request.id);
  }

  @override
  Future<void> cancel(String id) async {
    if (failCancel) throw StateError("controlled cancel failure");
    pending.remove(id);
  }
}
