import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/connection_screen.dart';
import 'package:note_agent/main.dart';
import 'package:note_agent/note_workspace.dart';
import 'package:note_agent/processing_recovery_screen.dart';
import 'package:note_agent/setup_screen.dart';

import 'support/ai_fixture.dart';
import 'support/no_cost_wording.dart';
import 'support/organize_now.dart';

class _LoopbackHttpOverrides extends HttpOverrides {}

/// No budget remains in the app (ADR 0004): no panel, limit, estimate or
/// cost wording, settings with only the Bailian key, recovery with 重试.
void main() {
  late AiFixture f;

  Future<NoteWorkspace> start(WidgetTester tester, {Size? size}) async {
    f = AiFixture();
    await tester.runAsync(() => f.start(devices: 1));
    addTearDown(() => tester.runAsync(f.close));
    tester.view.physicalSize = size ?? const Size(1400, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    return f.workspaces.first;
  }

  for (final width in [360.0, 1400.0]) {
    testWidgets('the app offers no budget panel or cost wording ($width)', (
      tester,
    ) async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final w = await start(tester, size: Size(width, 3000));
        await tester.pumpWidget(NoteAgentApp(initialWorkspace: w));
        await tester.pumpAndSettle();
        expectNoCostWording(tester);
        if (width < 720) {
          await tester.tap(find.byTooltip('更多操作'));
          await tester.pumpAndSettle();
          expect(find.text('设置'), findsOneWidget);
          expect(find.text('连接与设备'), findsOneWidget);
          expectNoCostWording(tester);
        }
        expect(find.textContaining('预算'), findsNothing);
        expect(find.byTooltip('AI 与共享预算'), findsNothing);
        await tester.pumpWidget(const SizedBox());
      }, _LoopbackHttpOverrides());
    });
  }

  testWidgets('settings show no prepaid, monthly or budget section', (
    tester,
  ) async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final w = await start(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: SetupScreen(workspace: w, connection: w.connection),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('设置'), findsOneWidget);
      expectNoCostWording(tester);
      await tester.pumpWidget(const SizedBox());
    }, _LoopbackHttpOverrides());
  });

  testWidgets('the AI connection is only the Bailian key', (tester) async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final w = await start(tester);
      await tester.pumpWidget(
        MaterialApp(home: ConnectionScreen(connection: w.connection)),
      );
      await tester.pumpAndSettle();
      expect(find.text('阿里云百炼（北京）'), findsOneWidget);
      expect(find.text('替换百炼 API Key'), findsWidgets);
      expectNoCostWording(tester);
      await tester.pumpWidget(const SizedBox());
    }, _LoopbackHttpOverrides());
  });

  testWidgets('a failed capture shows its status and 重试 only', (
    tester,
  ) async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final w = await start(tester);
      f.modelStatuses.add(400);
      await tester.runAsync(() async {
        final note = await w.captureText(title: '界面失败', text: '界面中恢复。');
        await w.organizeNow(note.id);
      });
      await tester.pumpWidget(
        MaterialApp(home: ProcessingFailuresScreen(workspace: w)),
      );
      await tester.pumpAndSettle();
      expect(find.text('界面失败'), findsOneWidget);
      expect(find.text(OrganizeStatus.failed.label), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, '重试'), findsOneWidget);
      expectNoCostWording(tester);
      await tester.pumpWidget(const SizedBox());
    }, _LoopbackHttpOverrides());
  });
}
