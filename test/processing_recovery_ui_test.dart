import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/processing_recovery_screen.dart';

import 'audio_queue_test.dart' show wave;
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
    'the failure list shows account problems and retries manually once',
    (tester) async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final f = BudgetFixture()..modelStatuses.add(401);
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
        expect(find.textContaining('Key、余额或预算'), findsOneWidget);
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

  testWidgets(
    'a transcript is corrected and a re-organization previewed before it is applied',
    (tester) async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final f = BudgetFixture();
        await tester.runAsync(() async {
          await f.start();
          final w = f.workspaces.first;
          await w.importAudio(
            original: await File('${f.root.path}/a.wav').writeAsBytes(wave()),
            submissionId: 'ui-reorganize',
          );
          await w.sendWaitingNow();
        });
        addTearDown(() => tester.runAsync(f.close));
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final w = f.workspaces.first;
        final note = w.notes.single;
        await tester.pumpWidget(
          MaterialApp(
            home: ReorganizeScreen(workspace: w, noteId: note.id),
          ),
        );
        await tester.enterText(
          find.byKey(const ValueKey('transcript-correction')),
          '更正后的完整转写。',
        );
        await _tap(tester, find.text('保存转写更正（不调用模型）'));
        await _until(tester, () => w.notes.single.originalText == '更正后的完整转写。');
        await _tap(tester, find.text('预估重新整理（不调用模型）'));
        await _until(
          tester,
          () => find.text('发送并生成预览（可能计费）').evaluate().isNotEmpty,
        );
        expect(f.modelRequests, hasLength(1));
        f.modelResult = {'kind': 'ordinary', 'title': '更正后', 'body': '预览正文。'};
        await _tap(tester, find.text('发送并生成预览（可能计费）'));
        await _until(tester, () => w.reorganizationPreviews.isNotEmpty);
        expect(find.text('预览正文。'), findsOneWidget);
        expect(w.notes.single.text, note.text);
        await _tap(tester, find.text('应用此预览'));
        await _until(tester, () => w.notes.single.text == '预览正文。');
        expect(f.modelRequests, hasLength(2));
        expect(f.audioRequests, 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      }, _LoopbackHttpOverrides());
    },
  );
}
