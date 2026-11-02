import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/processing_recovery_screen.dart';

import 'support/budget_fixture.dart';
import 'support/organize_now.dart';

class _LoopbackHttpOverrides extends HttpOverrides {}

Future<void> _tap(WidgetTester tester, Finder target) async {
  await tester.scrollUntilVisible(
    target,
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.runAsync(() async {
    await tester.tap(target);
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });
  await tester.pumpAndSettle();
}

Future<void> _until(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 200 && !done(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
  }
  expect(done(), true);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'the failure list shows a failed capture and retries manually once',
    (tester) async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final f = BudgetFixture()..modelStatuses.add(400);
        await tester.runAsync(() async {
          await f.start();
          final w = f.workspaces.first;
          final note = await w.captureText(title: '界面失败', text: '界面中恢复。');
          await w.organizeNow(note.id);
        });
        addTearDown(() => tester.runAsync(f.close));
        final w = f.workspaces.first;
        await tester.pumpWidget(
          MaterialApp(home: ProcessingFailuresScreen(workspace: w)),
        );
        expect(find.text('界面失败'), findsOneWidget);
        await _tap(tester, find.text('手动重试（另行预留，可能计费）'));
        await _until(
          tester,
          () =>
              f.modelRequests.length == 2 &&
              w.notes.single.text == '整理后的普通想法。' &&
              w.processingFailures.isEmpty,
        );
        await tester.pumpWidget(
          MaterialApp(home: ProcessingFailuresScreen(workspace: w)),
        );
        expect(find.text('没有需要恢复的处理。'), findsOneWidget);
        expect(f.modelRequests, hasLength(2));
        await tester.pumpWidget(const SizedBox());
      }, _LoopbackHttpOverrides());
    },
  );
}
