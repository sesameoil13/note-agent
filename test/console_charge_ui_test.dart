import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/budget_panel.dart';

import 'audio_queue_test.dart' show wave;
import 'support/async_settle.dart';
import 'support/budget_fixture.dart';

class _LoopbackHttpOverrides extends HttpOverrides {}

void main() {
  testWidgets(
    'a lost transcription receipt is cleared by entering the charge shown in the console',
    (tester) async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final f = BudgetFixture()..omitAudioCost = true;
        await tester.runAsync(() async {
          await f.start();
          final w = f.workspaces.first;
          final source = await w.importAudio(
            original: await File('${f.root.path}/lost.wav')
                .writeAsBytes(wave(seconds: 4)),
            submissionId: 'ui-lost-receipt',
          );
          await w.prepareAudioProcessing(source.id);
          await w.confirmAudioProcessing(source.id);
        });
        addTearDown(() => tester.runAsync(f.close));
        final w = f.workspaces.first;
        tester.view.physicalSize = const Size(1280, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(MaterialApp(home: BudgetPanel(workspace: w)));
        await pumpUntil(tester);
        await tester.pumpAndSettle();

        Future<void> tap(Finder target) async {
          await tester.ensureVisible(target);
          await tester.pumpAndSettle();
          await tester.runAsync(() async {
            await tester.tap(target);
            await Future<void>.delayed(const Duration(milliseconds: 150));
          });
          await pumpUntil(tester);
          await tester.pumpAndSettle();
        }

        await tap(find.text('按控制台账单记录费用'));
        Finder inDialog(Finder f) =>
            find.descendant(of: find.byType(AlertDialog), matching: f);
        expect(inDialog(find.text('转写')), findsOneWidget);
        expect(inDialog(find.textContaining('预留 ¥')), findsOneWidget);
        // Not an amount: refused without contacting the ledger.
        await tester.enterText(find.byType(TextField).last, '一块');
        await tap(find.text('记录'));
        expect(inDialog(find.textContaining('请输入金额')), findsOneWidget);
        await tester.enterText(find.byType(TextField).last, '0.001');
        await tap(find.text('记录'));

        await tester.runAsync(w.refreshBudget);
        expect(w.budget.spentCnyMicros, 1000);
        expect(w.budget.reservedCnyMicros, 0);
        expect(f.audioRequests, 1);
      }, _LoopbackHttpOverrides());
    },
  );

  testWidgets(
    'a completed recording can still record an organizing charge, and says when none is left',
    (tester) async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final f = BudgetFixture();
        await tester.runAsync(() async {
          await f.start();
          final w = f.workspaces.first;
          final source = await w.importAudio(
            original: await File('${f.root.path}/done.wav')
                .writeAsBytes(wave(seconds: 4)),
            submissionId: 'ui-completed',
          );
          await w.prepareAudioProcessing(source.id);
          await w.confirmAudioProcessing(source.id);
        });
        addTearDown(() => tester.runAsync(f.close));
        final w = f.workspaces.first;
        expect(w.audioJobs.single.status.name, 'completed');
        tester.view.physicalSize = const Size(1280, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(MaterialApp(home: BudgetPanel(workspace: w)));
        await pumpUntil(tester);
        await tester.pumpAndSettle();
        final button = find.text('按控制台账单记录费用');
        expect(button, findsOneWidget);
        await tester.ensureVisible(button);
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          await tester.tap(button);
          await Future<void>.delayed(const Duration(milliseconds: 150));
        });
        await pumpUntil(tester);
        await tester.pump();
        expect(find.text('没有待核对的请求。'), findsOneWidget);
      }, _LoopbackHttpOverrides());
    },
  );
}
