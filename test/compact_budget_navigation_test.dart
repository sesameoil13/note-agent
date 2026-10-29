import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/main.dart';
import 'package:note_agent/budget_panel.dart';

import 'support/budget_fixture.dart';

class _LoopbackHttpOverrides extends HttpOverrides {}

void main() {
  for (final width in [360.0, 800.0]) {
    testWidgets('compact app navigation reaches the budget panel ($width)', (
      tester,
    ) async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final f = BudgetFixture();
        await tester.runAsync(f.start);
        addTearDown(() => tester.runAsync(f.close));
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          NoteAgentApp(initialWorkspace: f.workspaces.first),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byTooltip('更多操作'), findsOneWidget);
        await tester.tap(find.byTooltip('更多操作'));
        await tester.pumpAndSettle();
        expect(find.text('AI 与共享预算'), findsOneWidget);
        expect(find.text('设置'), findsOneWidget);
        expect(find.text('连接与设备'), findsOneWidget);
        await tester.runAsync(() async {
          await tester.tap(find.text('AI 与共享预算'));
          await Future<void>.delayed(const Duration(milliseconds: 100));
        });
        await tester.pumpAndSettle();
        expect(find.byType(BudgetPanel), findsOneWidget);
        expect(f.audioRequests, 0);
        expect(f.modelRequests, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      }, _LoopbackHttpOverrides());
    });
  }
}
