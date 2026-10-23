import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/main.dart';
import 'package:note_agent/note_workspace.dart';

import 'support/pending_notification_fixture.dart';

void main() {
  testWidgets(
    'note details complete, snooze and reopen through the workspace; an alert completion updates the open App',
    (tester) async {
      final port = PendingNotifications();
      final setup = (await tester.runAsync(() async {
        final root = await Directory.systemTemp.createTemp('lifecycle-ui-');
        final w = await NoteWorkspace.open(
          localDirectory: Directory('${root.path}/local'),
          vaultDirectory: await Directory('${root.path}/vault').create(),
          notifications: port,
          clock: () => DateTime(2026, 10, 21, 8),
        );
        final n = await w.captureText(title: '采购安排', text: '买电池，交电费。');
        await w.resolveNoteActions(
          n.id,
          kind: NoteKind.todo,
          actions: const [
            WorkspaceAction(
              id: 'buy',
              text: '买电池',
              decision: ActionDecision.confirmed,
              reason: 'none',
            ),
            WorkspaceAction(
              id: 'pay',
              text: '交电费',
              decision: ActionDecision.confirmed,
              reason: 'none',
            ),
          ],
        );
        return (root, w, n);
      }))!;
      final (root, w, n) = setup;
      addTearDown(
        () => tester.runAsync(() async {
          await w.close();
          await port.signals.close();
          await root.delete(recursive: true);
        }),
      );
      tester.view.physicalSize = const Size(1280, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // Workspace operations do real file IO outside the fake clock.
      // Listeners created by the App run in the fake zone, so pump between waits.
      Future<void> waitFor(bool Function() done) async {
        for (var i = 0; i < 100 && !done(); i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
          await tester.pump();
        }
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pumpAndSettle();
        expect(done(), isTrue);
      }

      Future<void> tapAndWait(Finder finder, bool Function() done) async {
        await tester.runAsync(() => tester.tap(finder));
        await waitFor(done);
      }

      await tester.pumpWidget(NoteAgentApp(initialWorkspace: w));
      await tester.pumpAndSettle();
      await tester.tap(find.text('采购安排').first);
      await tester.pumpAndSettle();
      expect(find.text('完成'), findsNWidgets(2));
      expect(find.text('稍后提醒…'), findsNWidgets(2));

      await tester.tap(find.text('稍后提醒…').first);
      await tester.pumpAndSettle();
      expect(find.text('30 分钟后（默认）'), findsOneWidget);
      await tapAndWait(
        find.text('60 分钟后'),
        () => w.reminders.any((r) => r.snoozed),
      );
      final buy = w.reminders.firstWhere((r) => r.actionId == 'buy');
      expect(buy.time, DateTime(2026, 10, 21, 9));
      expect(find.textContaining('已稍后提醒'), findsOneWidget);

      await tapAndWait(
        find.text('完成').first,
        () => w.notes.single.actions.first.completed,
      );
      expect(w.actionState(n.id, 'buy').completed, true);
      expect(find.text('■ 买电池'), findsOneWidget);
      expect(find.textContaining('已完成，提醒已取消'), findsOneWidget);
      expect(find.text('重新开启'), findsOneWidget);

      // A completion chosen on the system alert reaches the running App.
      final pay = port.pending.values.singleWhere(
        (r) => r.payload['actionId'] == 'pay',
      );
      port.interactions.add(
        NotificationInteraction(
          id: pay.id,
          payload: pay.payload,
          actionIdentifier: 'complete',
        ),
      );
      await tester.runAsync(() async => port.signals.add(null));
      await waitFor(() => w.notes.single.actions.last.completed);
      expect(w.actionState(n.id, 'pay').completed, true);
      expect(find.text('■ 交电费'), findsOneWidget);
      expect(w.reminders, isEmpty);

      await tester.tap(find.text('重新开启').first);
      await tester.pumpAndSettle();
      expect(find.text('重新开启后的提醒日期'), findsOneWidget);
      final picker = tester.element(find.text('重新开启后的提醒日期'));
      await tester.tap(
        find.text(MaterialLocalizations.of(picker).cancelButtonLabel),
      );
      await tester.pumpAndSettle();
      expect(w.actionState(n.id, 'buy').completed, true);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
