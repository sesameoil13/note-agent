import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/budget_panel.dart';
import 'package:note_agent/document_panel.dart';
import 'package:note_agent/note_workspace.dart';

import 'support/budget_fixture.dart';

class _LoopbackHttpOverrides extends HttpOverrides {}

void main() {
  testWidgets(
    'phone document review discloses omissions and reserves only on explicit action',
    (tester) async {
      final f = BudgetFixture();
      final w = (await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(() async {
          await f.start();
          await f.workspaces.first.importDocument(
            original: File('test/fixtures/word/mixed.docx'),
          );
          return f.workspaces.first;
        }, _LoopbackHttpOverrides()),
      ))!;
      addTearDown(() => tester.runAsync(f.close));
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: BudgetPanel(workspace: w, noteId: w.notes.single.id),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('预估并预留（不调用模型）'),
        300,
        scrollable: find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(find.textContaining('扫描页、图片及其他未处理区域不会被补写'), findsOneWidget);
      expect(w.textJobs, isEmpty);
      expect(f.modelRequests, isEmpty);
      await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(() async {
          await tester.tap(find.text('预估并预留（不调用模型）'));
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }, _LoopbackHttpOverrides()),
      );
      await tester.pumpAndSettle();
      expect(w.textJobs.single.status, TextProcessingStatus.prepared);
      expect(f.modelRequests, isEmpty);
      await tester.scrollUntilVisible(
        find.text('确认发送并整理（可能产生费用）'),
        200,
        scrollable: find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(() async {
          await tester.tap(find.text('确认发送并整理（可能产生费用）'));
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }, _LoopbackHttpOverrides()),
      );
      await tester.pumpAndSettle();
      expect(w.textJobs.single.status, TextProcessingStatus.completed);
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

  testWidgets('image-only document visibly refuses an AI reservation', (
    tester,
  ) async {
    final f = BudgetFixture();
    final w = (await tester.runAsync(
      () => HttpOverrides.runWithHttpOverrides(() async {
        await f.start();
        await f.workspaces.first.importDocument(
          original: File('test/fixtures/word/images-only.docx'),
        );
        return f.workspaces.first;
      }, _LoopbackHttpOverrides()),
    ))!;
    addTearDown(() => tester.runAsync(f.close));
    await tester.pumpWidget(
      MaterialApp(
        home: BudgetPanel(workspace: w, noteId: w.notes.single.id),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('预估并预留（不调用模型）'),
      300,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.textContaining('扫描页与图片尚未识别'), findsOneWidget);
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, '预估并预留（不调用模型）'),
          )
          .onPressed,
      isNull,
    );
    expect(w.textJobs, isEmpty);
    expect(f.modelRequests, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
