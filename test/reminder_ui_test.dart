import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/note_workspace.dart';
import 'package:note_agent/reminder_screen.dart';

void main() {
  testWidgets(
    'settings change future defaults and show a separate existing-plan preview',
    (tester) async {
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('reminder-ui-'),
      ))!;
      final w = (await tester.runAsync(() async {
        final w = await NoteWorkspace.open(
          localDirectory: Directory('${root.path}/local'),
          vaultDirectory: await Directory('${root.path}/vault').create(),
          clock: () => DateTime(2026, 10, 21, 8),
        );
        final n = await w.captureText(title: '采购笔记', text: '买电池');
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
        return w;
      }))!;
      addTearDown(
        () => tester.runAsync(() async {
          await w.close();
          await root.delete(recursive: true);
        }),
      );
      await tester.pumpWidget(MaterialApp(home: ReminderScreen(workspace: w)));
      expect(find.textContaining('通知功能尚未连接'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextField, '无日期／时间待确认'),
        '10:30',
      );
      await tester.scrollUntilVisible(
        find.text('保存默认时间（仅新增事项）'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.runAsync(() async {
        await tester.tap(find.text('保存默认时间（仅新增事项）'));
      });
      await tester.pumpAndSettle();
      expect(w.reminderDefaults.tomorrowMinute, 630);
      expect(w.reminders.single.time, DateTime(2026, 10, 22, 9));
      await tester.ensureVisible(find.text('预览应用到现有默认提醒'));
      await tester.tap(find.text('预览应用到现有默认提醒'));
      await tester.pumpAndSettle();
      expect(find.textContaining('09:00 → 2026-10-22 10:30'), findsOneWidget);
      await tester.tap(find.text('确认应用 1 项'));
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      expect(w.reminders.single.time, DateTime(2026, 10, 22, 10, 30));
      expect(w.reminders.single.status, ReminderStatus.blocked);
      await tester.ensureVisible(find.text('修改提醒时间'));
      await tester.runAsync(() async {
        await tester.tap(find.text('修改提醒时间'));
      });
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, '提醒时间（YYYY-MM-DD HH:mm）'),
        '2026-10-29 16:45:30.123456',
      );
      await tester.runAsync(() async {
        await tester.tap(find.text('确认新时间'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      expect(
        w.reminders.single.time,
        DateTime(2026, 10, 29, 16, 45, 30, 123, 456),
      );
      expect(w.reminders.single.explicitTime, true);

      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
