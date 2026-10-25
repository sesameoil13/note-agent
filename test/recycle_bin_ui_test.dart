import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/main.dart';
import 'package:note_agent/note_workspace.dart';

import 'support/pending_notification_fixture.dart';

void main() {
  testWidgets(
    'archive, delete into the 回收站, restore and decide a missed reminder from the App',
    (tester) async {
      final port = PendingNotifications();
      var now = DateTime(2026, 10, 21, 8);
      final setup = (await tester.runAsync(() async {
        final root = await Directory.systemTemp.createTemp('recycle-ui-');
        final w = await NoteWorkspace.open(
          localDirectory: Directory('${root.path}/local'),
          vaultDirectory: await Directory('${root.path}/vault').create(),
          notifications: port,
          clock: () => now,
        );
        final n = await w.captureText(title: '采购安排', text: '明天十点买电池。');
        await w.resolveNoteActions(
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
        await w.captureText(title: '周报', text: '本周进展。');
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

      await tapAndWait(find.text('归档'), () => w.archivedNotes.isNotEmpty);
      expect(find.text('采购安排'), findsNothing);
      expect(port.pending, hasLength(1));

      await tester.tap(find.byTooltip('归档与回收站'));
      await tester.pumpAndSettle();
      expect(find.text('采购安排'), findsOneWidget);
      await tapAndWait(
        find.text('取消归档'),
        () => find.text('已放回最近记录。').evaluate().isNotEmpty,
      );
      expect(w.archivedNotes, isEmpty);
      await tester.pageBack();
      await tester.pumpAndSettle();

      await tester.tap(find.text('采购安排').first);
      await tester.pumpAndSettle();
      await tapAndWait(find.text('移入回收站'), () => w.recycleBin.isNotEmpty);
      expect(find.text('采购安排'), findsNothing);
      expect(port.pending, isEmpty);

      now = DateTime(2026, 10, 23, 8);
      await tester.tap(find.byTooltip('归档与回收站'));
      await tester.pumpAndSettle();
      expect(find.text('采购安排'), findsOneWidget);
      await tapAndWait(
        find.text('恢复'),
        () => find.text('已恢复「采购安排」。').evaluate().isNotEmpty,
      );
      expect(w.recycleBin, isEmpty);
      expect(find.textContaining('买电池'), findsOneWidget);
      expect(find.text('重新安排…'), findsOneWidget);
      await tapAndWait(find.text('不再提醒'), () => w.reminderDecisions.isEmpty);
      expect(port.pending, isEmpty);
      expect(w.actionState(n.id, 'buy').completed, isFalse);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('采购安排'), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'purging asks for confirmation first, and the whole 回收站 can be restored or purged at once',
    (tester) async {
      final setup = (await tester.runAsync(() async {
        final root = await Directory.systemTemp.createTemp('recycle-purge-ui-');
        final w = await NoteWorkspace.open(
          localDirectory: Directory('${root.path}/local'),
          vaultDirectory: await Directory('${root.path}/vault').create(),
        );
        for (final title in ['甲', '乙', '丙']) {
          final n = await w.captureText(title: title, text: '$title的内容');
          await w.deleteNote(n.id);
        }
        return (root, w);
      }))!;
      final (root, w) = setup;
      addTearDown(
        () => tester.runAsync(() async {
          await w.close();
          await root.delete(recursive: true);
        }),
      );
      tester.view.physicalSize = const Size(1280, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

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

      final dialog = find.byType(AlertDialog);
      Finder inDialog(String text) =>
          find.descendant(of: dialog, matching: find.text(text));
      Finder purgeOf(String title) => find.descendant(
        of: find.widgetWithText(ListTile, title),
        matching: find.text('永久清除'),
      );

      await tester.pumpWidget(NoteAgentApp(initialWorkspace: w));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('归档与回收站'));
      await tester.pumpAndSettle();

      await tester.tap(purgeOf('甲'));
      await tester.pumpAndSettle();
      expect(find.textContaining('无法恢复'), findsOneWidget);
      expect(find.textContaining('Obsidian Sync'), findsOneWidget);
      await tester.tap(inDialog('取消'));
      await tester.pumpAndSettle();
      expect(w.recycleBin, hasLength(3));

      // The purge itself does file IO, so the confirming flow runs for real.
      await tester.runAsync(() => tester.tap(purgeOf('甲')));
      await tester.pumpAndSettle();
      await tester.runAsync(() => tester.tap(inDialog('永久清除')));
      await waitFor(() => w.recycleBin.length == 2);
      expect(find.text('甲'), findsNothing);

      await tester.runAsync(() => tester.tap(find.text('全部恢复')));
      await waitFor(() => w.recycleBin.isEmpty);
      expect(w.notes.map((n) => n.title).toSet(), {'乙', '丙'});

      await tester.runAsync(() => w.deleteNote(w.notes.first.id));
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('归档与回收站'));
      await tester.pumpAndSettle();
      await tester.runAsync(() => tester.tap(find.text('全部永久清除')));
      await tester.pumpAndSettle();
      expect(find.textContaining('1 项'), findsOneWidget);
      await tester.runAsync(() => tester.tap(inDialog('永久清除')));
      await waitFor(() => w.recycleBin.isEmpty);
      expect(w.notes, hasLength(1));
      expect(find.text('回收站是空的。'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
