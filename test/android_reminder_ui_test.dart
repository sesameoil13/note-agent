import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/note_workspace.dart';
import 'package:note_agent/reminder_screen.dart';

import 'support/pending_notification_fixture.dart';

void main() {
  testWidgets('reminder settings say plainly when alarms may arrive late', (
    tester,
  ) async {
    final root = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('android-reminder-ui-'),
    ))!;
    final port = PendingNotifications()..exactTiming = false;
    final w = (await tester.runAsync(() async {
      final w = await NoteWorkspace.open(
        localDirectory: Directory('${root.path}/local'),
        vaultDirectory: await Directory('${root.path}/vault').create(),
        clock: () => DateTime(2026, 10, 21, 8),
        notifications: port,
      );
      await w.reconcileReminders();
      return w;
    }))!;
    addTearDown(
      () => tester.runAsync(() async {
        await w.close();
        await root.delete(recursive: true);
      }),
    );
    await tester.pumpWidget(MaterialApp(home: ReminderScreen(workspace: w)));
    expect(find.text('系统通知已允许'), findsOneWidget);
    expect(find.textContaining('精确闹钟未允许'), findsOneWidget);
  });
}
