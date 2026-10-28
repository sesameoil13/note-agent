import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/document_panel.dart';
import 'package:note_agent/main.dart';
import 'package:note_agent/note_workspace.dart';

import 'support/budget_fixture.dart';
import 'support/async_settle.dart';

class _LoopbackHttpOverrides extends HttpOverrides {}

void main() {
  testWidgets(
    'a document organized after extraction keeps its extracted version and original',
    (tester) async {
      final f = BudgetFixture();
      final w = (await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(() async {
          await f.start();
          final w = f.workspaces.first;
          await w.importDocument(
            original: File('test/fixtures/word/mixed.docx'),
          );
          await w.sendWaitingNow();
          return w;
        }, _LoopbackHttpOverrides()),
      ))!;
      addTearDown(() => tester.runAsync(f.close));
      expect(w.organizeStatus(w.notes.single.id), OrganizeStatus.organized);
      expect(f.modelRequests, hasLength(1));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DocumentStatusView(
              workspace: w,
              note: w.notes.single,
              onChanged: () {},
            ),
          ),
        ),
      );
      await pumpUntil(tester);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, '重新提取文档'),
            )
            .onPressed,
        isNull,
      );
      expect(find.text('已有 AI 任务，保留当前提取版本和文档原件。'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('an image-only document is never sent and the note says why', (
    tester,
  ) async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final f = BudgetFixture();
      await tester.runAsync(() async {
        await f.start();
        await f.workspaces.first.importDocument(
          original: File('test/fixtures/word/images-only.docx'),
        );
      });
      addTearDown(() => tester.runAsync(f.close));
      final w = f.workspaces.first;
      tester.view.physicalSize = const Size(1280, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(NoteAgentApp(initialWorkspace: w));
      await pumpUntil(
        tester,
        () => w.organizeStatus(w.notes.single.id) == OrganizeStatus.failed,
      );
      await pumpUntil(tester);
      expect(find.textContaining('本机已保存 · 失败'), findsOneWidget);
      await tester.tap(find.text(w.notes.single.title).first);
      await pumpUntil(tester);
      expect(find.textContaining('整理：失败'), findsOneWidget);
      expect(find.textContaining('扫描页与图片尚未识别'), findsOneWidget);
      expect(f.modelRequests, isEmpty);
      await tester.pumpWidget(const SizedBox());
    }, _LoopbackHttpOverrides());
  });
}
