import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/main.dart';
import 'package:note_agent/note_workspace.dart';

import 'support/pending_notification_fixture.dart';
import 'support/async_settle.dart';

void main() {
  testWidgets(
    'cold and foreground notification taps enter the same pending list and decisions update the persistent count',
    (tester) async {
      final fixture = (await tester.runAsync(() async {
        final root = await Directory.systemTemp.createTemp('pending-tap-ui-');
        final port = PendingNotifications();
        final w = await NoteWorkspace.open(
          localDirectory: Directory('${root.path}/local'),
          vaultDirectory: await Directory('${root.path}/vault').create(),
          notifications: port,
        );
        final n = await w.captureText(title: '采购建议', text: '他说可以考虑购买电池。');
        await w.resolveNoteActions(
          n.id,
          kind: NoteKind.todo,
          actions: [
            const WorkspaceAction(id: 'buy', text: '购买电池', reason: 'quote'),
          ],
        );
        final r = port.pending.values.single;
        port.interactions.add(
          NotificationInteraction(id: r.id, payload: r.payload),
        );
        return (root, port, w, n, r);
      }))!;
      final (root, port, w, n, r) = fixture;
      addTearDown(
        () => tester.runAsync(() async {
          await w.close();
          await port.signals.close();
          await root.delete(recursive: true);
        }),
      );
      await tester.pumpWidget(NoteAgentApp(initialWorkspace: w));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pumpAndSettle();
      expect(find.text('待确认行动与主题'), findsOneWidget);
      expect(find.text('采购建议').last, findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('待确认 1'), findsOneWidget);
      port.interactions.add(
        NotificationInteraction(id: r.id, payload: r.payload),
      );
      port.signals.add(null);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pumpAndSettle();
      expect(find.text('待确认行动与主题'), findsOneWidget);
      await tester.tap(find.text('采购建议').last);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('仅保留为普通笔记'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.runAsync(() async {
        await tester.tap(find.text('仅保留为普通笔记'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await pumpUntil(tester, () => w.pendingConfirmationNotes.isEmpty);
      await tester.pumpAndSettle();
      // Action screen closes after the local decision; the common list refreshes.
      expect(w.pendingConfirmationNotes, isEmpty);
      expect(w.notes.single.originalText, n.text);
      expect(find.text('没有待确认内容。'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('待确认 0'), findsOneWidget);
      expect(port.permissionRequests, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
