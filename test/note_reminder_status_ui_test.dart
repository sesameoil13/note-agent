import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/main.dart';
import 'package:note_agent/note_workspace.dart';

import 'support/pending_notification_fixture.dart';

void main() {
  testWidgets(
    'note action details use their own reminder plan and report system acceptance honestly',
    (tester) async {
      var now = DateTime(2026, 10, 21, 8);
      final port = PendingNotifications()..failInspect = true;
      final setup = (await tester.runAsync(() async {
        final root = await Directory.systemTemp.createTemp(
          'note-reminder-status-',
        );
        final w = await NoteWorkspace.open(
          localDirectory: Directory('${root.path}/local'),
          vaultDirectory: await Directory('${root.path}/vault').create(),
          notifications: port,
          clock: () => now,
        );
        final planned = await w.captureText(
          title: '采购安排',
          text: '需要购买电池，时间待定。',
        );
        await w.resolveNoteActions(
          planned.id,
          kind: NoteKind.todo,
          actions: [
            const WorkspaceAction(
              id: 'shared-action',
              text: '购买电池',
              decision: ActionDecision.confirmed,
              timeStatus: ActionTimeStatus.unresolved,
              timeExpression: '稍后',
            ),
          ],
        );
        final uncertain = await w.captureText(
          title: '别人的建议',
          text: '他说可以考虑联系同事。',
        );
        await w.resolveNoteActions(
          uncertain.id,
          kind: NoteKind.todo,
          actions: [
            const WorkspaceAction(
              id: 'shared-action',
              text: '联系同事',
              reason: 'quote',
            ),
          ],
        );
        return (root, w);
      }))!;
      final (root, w) = setup;
      addTearDown(
        () => tester.runAsync(() async {
          await w.close();
          await port.signals.close();
          await root.delete(recursive: true);
        }),
      );
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      Future<void> open(String title) async {
        await tester.pumpWidget(
          NoteAgentApp(key: UniqueKey(), initialWorkspace: w),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('历史记录'));
        await tester.pumpAndSettle();
        await tester.tap(find.text(title));
        await tester.pumpAndSettle();
      }

      expect(w.reminders.single.status, ReminderStatus.pending);
      await open('采购安排');
      expect(find.textContaining('等待安排'), findsOneWidget);
      expect(find.textContaining('2026-10-22 09:00'), findsOneWidget);
      expect(find.textContaining('时间待确认，当前使用默认提醒'), findsOneWidget);
      expect(find.text('尚未排程提醒'), findsNothing);

      port.failInspect = false;
      port.permission = NotificationPermission.denied;
      await tester.runAsync(w.reconcileReminders);
      expect(w.reminders.single.status, ReminderStatus.blocked);
      await open('采购安排');
      expect(find.textContaining('等待通知权限'), findsOneWidget);

      port.permission = NotificationPermission.allowed;
      port.failSchedule = true;
      await tester.runAsync(w.reconcileReminders);
      expect(w.reminders.single.status, ReminderStatus.failed);
      await open('采购安排');
      expect(find.textContaining('安排未完成，可重试'), findsOneWidget);

      port.failSchedule = false;
      await tester.runAsync(w.reconcileReminders);
      expect(w.reminders.single.status, ReminderStatus.scheduled);
      await open('采购安排');
      expect(find.textContaining('系统已接受计划'), findsOneWidget);
      expect(find.textContaining('已送达'), findsNothing);
      expect(find.text('尚未排程提醒'), findsNothing);

      await open('别人的建议');
      expect(find.text('尚未排程提醒'), findsOneWidget);
      expect(find.textContaining('系统已接受计划'), findsNothing);

      now = DateTime(2026, 10, 22, 10);
      port.pending.remove(w.reminders.single.id);
      await tester.runAsync(w.reconcileReminders);
      expect(w.reminders.single.status, ReminderStatus.elapsed);
      await open('采购安排');
      expect(find.textContaining('提醒时间已过'), findsOneWidget);
      expect(find.textContaining('已送达'), findsNothing);
      expect(port.permissionRequests, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
