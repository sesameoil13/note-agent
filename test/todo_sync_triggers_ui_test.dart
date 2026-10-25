import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/main.dart';
import 'package:note_agent/note_workspace.dart';

import 'support/todo_sync_fixture.dart';

/// The App sends to-do and deletion-mark operations as soon as they are made,
/// without waiting for the next resume: a paired device sees them on its next
/// pull. Uses the loopback Workerd fixture; device A is driven through the UI.
class _LoopbackHttpOverrides extends HttpOverrides {}

void main() {
  testWidgets(
    'deleting, restoring, purging and completing from an alert reach the paired device without a resume',
    (tester) async {
      // Real loopback HTTP for the fixture and for syncs the App starts.
      final mocked = HttpOverrides.current;
      HttpOverrides.global = _LoopbackHttpOverrides();
      addTearDown(() => HttpOverrides.global = mocked);
      final f = TodoSyncFixture();
      final n = (await tester.runAsync(() async {
        await f.start();
        final n = await f.todo(0);
        await f.todo(1);
        return n;
      }))!;
      addTearDown(() => tester.runAsync(f.close));
      final a = f.workspaces[0], b = f.workspaces[1];
      tester.view.physicalSize = const Size(1280, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      /// Polls device B (pulling from the Worker) until [done] holds.
      Future<void> seenOnB(bool Function() seen) async {
        bool done() => seen() && a.todoSync.pendingOperations == 0;
        for (var i = 0; i < 100 && !done(); i++) {
          await tester.runAsync(() async {
            await Future<void>.delayed(const Duration(milliseconds: 50));
            await b.syncTodos();
          });
          await tester.pump();
        }
        expect(seen(), isTrue);
        expect(a.todoSync.pendingOperations, 0);
      }

      await tester.pumpWidget(NoteAgentApp(initialWorkspace: a));
      await tester.pumpAndSettle();

      // Completion from a system alert while the App is in the foreground.
      final alert = f.alert(0, 'call')!;
      await tester.runAsync(() async {
        f.ports[0].interactions.add(
          NotificationInteraction(
            id: alert.id,
            payload: alert.payload,
            actionIdentifier: 'complete',
          ),
        );
        f.ports[0].signals.add(null);
      });
      await seenOnB(() => b.actionState(n.id, 'call').completed);

      // Delete from the note view.
      await tester.tap(find.text('安排').first);
      await tester.pumpAndSettle();
      await tester.runAsync(() => tester.tap(find.text('移入回收站')));
      await seenOnB(() => b.notes.isEmpty && b.recycleBin.isNotEmpty);

      // Restore from the 回收站.
      await tester.tap(find.byTooltip('归档与回收站'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('恢复').first,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.runAsync(() => tester.tap(find.text('恢复').first));
      await seenOnB(() => b.notes.isNotEmpty && b.recycleBin.isEmpty);

      // Delete again, then purge from the 回收站 after confirming.
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('安排').first);
      await tester.pumpAndSettle();
      await tester.runAsync(() => tester.tap(find.text('移入回收站')));
      await seenOnB(() => b.recycleBin.isNotEmpty);
      await tester.tap(find.byTooltip('归档与回收站'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('永久清除').first,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('永久清除').first);
      await tester.pumpAndSettle();
      await tester.runAsync(() => tester.tap(find.text('永久清除').last));
      await seenOnB(() => b.recycleBin.isEmpty && b.notes.isEmpty);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
