import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/note_workspace.dart';

import 'support/pending_notification_fixture.dart';
import 'support/budget_fixture.dart';

void main() {
  test('new pending actions form one quiet durable burst and resolved items leave its body', () async {
    final root = await Directory.systemTemp.createTemp('pending-notice-');
    var now = DateTime(2026, 10, 22, 8);
    final port = PendingNotifications();
    final local = Directory('${root.path}/local');
    final vault = await Directory('${root.path}/vault').create();
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
    final a = await w.captureText(title: '相同标题', text: '引用采购');
    await w.resolveNoteActions(
      a.id,
      kind: NoteKind.todo,
      actions: [const WorkspaceAction(id: 'buy', text: '买电池', reason: 'quote')],
    );
    expect(port.pending.length, 1);
    final first = port.pending.values.single;
    expect(first.time, DateTime(2026, 10, 22, 8, 0, 30));
    expect(first.body, '1 条笔记有待确认内容，点击查看。');
    now = now.add(const Duration(seconds: 10));
    final b = await w.captureText(title: '相同标题', text: '假设联系');
    await w.resolveNoteActions(
      b.id,
      kind: NoteKind.todo,
      actions: [
        const WorkspaceAction(id: 'ask', text: '联系', reason: 'hypothesis'),
      ],
    );
    expect(port.pending.keys.single, first.id);
    expect(port.pending.values.single.body, '2 条笔记有待确认内容，点击查看。');
    expect(port.pending.values.single.time, DateTime(2026, 10, 22, 8, 0, 30));
    expect(w.pendingConfirmationItems.map((i) => i.kind), [
      PendingConfirmationKind.action,
      PendingConfirmationKind.action,
    ]);
    await w.resolveNoteActions(a.id, kind: NoteKind.ordinary, actions: []);
    expect(port.pending.values.single.body, '1 条笔记有待确认内容，点击查看。');
    now = now.add(const Duration(minutes: 1));
    final schedules = port.schedules;
    await w.close();
    port.pending.clear();
    port.accepted.clear();
    w = await NoteWorkspace.open(
      localDirectory: local,
      vaultDirectory: vault,
      notifications: port,
      clock: () => now,
    );
    await w.reconcileReminders();
    expect(port.schedules, schedules);
    expect(w.pendingConfirmationNotes.single.id, b.id);
    expect(port.permissionRequests, 0);
  });
  test('denied permission keeps pending usable then alerts once on explicit allowance; unknown never sends', () async {
    final root = await Directory.systemTemp.createTemp('pending-denied-');
    var now = DateTime(2026, 10, 22, 8);
    final port = PendingNotifications()
      ..permission = NotificationPermission.denied;
    final local = Directory('${root.path}/local');
    final vault = await Directory('${root.path}/vault').create();
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
    final n = await w.captureText(title: '权限拒绝', text: '假设购买');
    await w.resolveNoteActions(
      n.id,
      kind: NoteKind.todo,
      actions: [
        const WorkspaceAction(id: 'buy', text: '购买', reason: 'hypothesis'),
      ],
    );
    expect(port.schedules, 0);
    expect(port.permissionRequests, 0);
    expect(w.pendingConfirmationNotes.length, 1);
    now = now.add(const Duration(minutes: 5));
    await w.close();
    w = await NoteWorkspace.open(
      localDirectory: local,
      vaultDirectory: vault,
      notifications: port,
      clock: () => now,
    );
    expect(port.schedules, 0);
    expect(w.pendingConfirmationItems.single.reason, 'hypothesis');
    final b = await w.captureText(title: '另一条建议', text: '有人建议联系');
    await w.resolveNoteActions(
      b.id,
      kind: NoteKind.todo,
      actions: [const WorkspaceAction(id: 'ask', text: '联系', reason: 'quote')],
    );

    port.failInspect = true;
    await w.requestNotificationPermission();
    expect(port.schedules, 0);
    expect(port.permissionRequests, 1);
    port.failInspect = false;
    port.failSchedule = true;
    await w.reconcileReminders();
    expect(port.schedules, 0);
    port.failSchedule = false;
    await w.reconcileReminders();
    expect(port.schedules, 1);
    expect(port.pending.values.single.immediate, true);
    expect(port.pending.values.single.body, '2 条笔记有待确认内容，点击查看。');
    await w.resolveNoteActions(b.id, kind: NoteKind.ordinary, actions: []);
    await w.reconcileReminders();
    expect(port.schedules, 1);
    await w.resolveNoteActions(n.id, kind: NoteKind.ordinary, actions: []);
    expect(port.pending, isEmpty);
    expect(w.pendingConfirmationItems, isEmpty);
    await w.resolveNoteActions(
      n.id,
      kind: NoteKind.todo,
      actions: [const WorkspaceAction(id: 'buy', text: '购买', reason: 'quote')],
    );
    expect(
      port.schedules,
      2,
    ); // A new unresolved occurrence after a real decision.
  });

  test('typed model topics and actions share one burst; local processing updates list without a model resend', () async {
    final f = BudgetFixture();
    await f.start();
    addTearDown(f.close);
    final port = PendingNotifications();
    final old = f.workspaces.first;
    await old.close();
    final w = f.workspaces[0] = await NoteWorkspace.open(
      localDirectory: Directory('${f.root.path}/local0'),
      vaultDirectory: Directory('${f.root.path}/vault0'),
      connection: old.connection,
      notifications: port,
      clock: () => DateTime(2026, 10, 22, 8),
    );
    final n = await w.captureText(title: '观察', text: '他说可以考虑购买电池。');
    f.modelResult = {
      'manifestVersion': 3,
      'kind': 'review',
      'title': '采购观察',
      'body': '记录采购建议。',
      'actions': [
        {
          'text': '购买电池',
          'reason': 'quote',
          'timeExpression': '',
          'timeStatus': 'absent',
        },
      ],
      'associations': [],
      'newTopics': [
        {'title': '采购建议', 'reason': '记录采购建议。'},
      ],
    };
    await w.processTextNote(n.id);
    expect(w.pendingConfirmationItems.map((i) => i.kind).toSet(), {
      PendingConfirmationKind.action,
      PendingConfirmationKind.topic,
    });
    expect(port.pending.length, 1);
    expect(port.pending.values.single.body, '1 条笔记有待确认内容，点击查看。');
    final ids = w.pendingConfirmationItems.map((i) => i.id).toSet();
    await w.renameNote(n.id, title: '修改标题');
    expect(w.pendingConfirmationItems.map((i) => i.id).toSet(), ids);
    final topic = w.pendingTopicSuggestions.single;
    await w.ignoreTopicSuggestion(topic.id);
    expect(w.pendingConfirmationNotes.length, 1);
    await w.resolveNoteActions(n.id, kind: NoteKind.ordinary, actions: []);
    expect(w.pendingConfirmationNotes, isEmpty);
    expect(port.pending, isEmpty);
    expect(f.modelRequests.length, 1);
    expect(await File(w.notes.single.sourcePath).readAsString(), n.text);
  });

  test('notification navigation validates scope kind and durable group; other consumers retain their responses', () async {
    final root = await Directory.systemTemp.createTemp('pending-navigation-');
    final port = PendingNotifications();
    final w = await NoteWorkspace.open(
      localDirectory: Directory('${root.path}/local'),
      vaultDirectory: await Directory('${root.path}/vault').create(),
      notifications: port,
    );
    addTearDown(() async {
      await w.close();
      await root.delete(recursive: true);
    });
    final n = await w.captureText(title: '待确认', text: '建议');
    await w.resolveNoteActions(
      n.id,
      kind: NoteKind.todo,
      actions: [const WorkspaceAction(id: 'a', text: '采购', reason: 'quote')],
    );
    final request = port.pending.values.single;
    port.interactions.addAll([
      NotificationInteraction(
        id: request.id,
        payload: {...request.payload, 'kind': 'actionReminder'},
      ),
      NotificationInteraction(
        id: request.id,
        payload: {...request.payload, 'vault': 'other-vault'},
      ),
      NotificationInteraction(
        id: 'stale',
        payload: {...request.payload, 'groupId': 'stale'},
      ),
    ]);
    expect(await w.takePendingConfirmationNavigation(), false);
    expect(port.interactions.length, 2);
    port.interactions.add(
      NotificationInteraction(id: request.id, payload: request.payload),
    );
    expect(await w.takePendingConfirmationNavigation(), true);
    expect(await w.takePendingConfirmationNavigation(), false);
    await w.resolveNoteActions(n.id, kind: NoteKind.ordinary, actions: []);
    port.interactions.add(
      NotificationInteraction(id: request.id, payload: request.payload),
    );
    expect(await w.takePendingConfirmationNavigation(), false);
  });
  test('content without extracted actions still has one typed pending event and stays isolated from another vault', () async {
    final f = BudgetFixture();
    await f.start();
    addTearDown(f.close);
    final port = PendingNotifications();
    final old = f.workspaces.first;
    await old.close();
    final w = f.workspaces[0] = await NoteWorkspace.open(
      localDirectory: Directory('${f.root.path}/local0'),
      vaultDirectory: Directory('${f.root.path}/vault0'),
      connection: old.connection,
      notifications: port,
    );
    final n = await w.captureText(title: '含义待核对', text: '含义不明的记录');
    f.modelResult = {
      'manifestVersion': 3,
      'kind': 'review',
      'title': '含义待核对',
      'body': '含义不明的记录',
      'actions': [],
      'associations': [],
      'newTopics': [],
    };
    await w.processTextNote(n.id);
    expect(
      w.pendingConfirmationItems.single.kind,
      PendingConfirmationKind.content,
    );
    expect(w.pendingConfirmationNotes.single.id, n.id);
    final request = port.pending.values.single;
    await w.close();
    final other = await NoteWorkspace.open(
      localDirectory: Directory('${f.root.path}/local0'),
      vaultDirectory: Directory('${f.root.path}/vault1'),
      notifications: port,
    );
    expect(other.pendingConfirmationNotes, isEmpty);
    port.interactions.add(
      NotificationInteraction(id: request.id, payload: request.payload),
    );
    expect(await other.takePendingConfirmationNavigation(), false);
    expect(port.interactions.length, 1);
    await other.close();
    final reopened = f.workspaces[0] = await NoteWorkspace.open(
      localDirectory: Directory('${f.root.path}/local0'),
      vaultDirectory: Directory('${f.root.path}/vault0'),
      connection: old.connection,
      notifications: port,
    );
    expect(await reopened.takePendingConfirmationNavigation(), true);
    final schedules = port.schedules;
    await reopened.resolveNoteActions(
      n.id,
      kind: NoteKind.ordinary,
      actions: [],
    );
    expect(reopened.pendingConfirmationItems, isEmpty);
    expect(port.schedules, schedules);
    expect(f.modelRequests.length, 1);
  });
}
