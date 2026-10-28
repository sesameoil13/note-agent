import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/main.dart';

import 'support/ai_fixture.dart';
import 'support/async_settle.dart';

class _LoopbackHttpOverrides extends HttpOverrides {}

void main() {
  testWidgets(
    'saved text is organized with no confirm step and the note shows 已整理',
    (tester) async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final f = AiFixture();
        await tester.runAsync(() => f.start(devices: 1));
        addTearDown(() => tester.runAsync(f.close));
        tester.view.physicalSize = const Size(1280, 1100);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          NoteAgentApp(initialWorkspace: f.workspaces.first),
        );
        await pumpUntil(tester);
        await tester.enterText(find.widgetWithText(TextField, '标题'), '想法');
        await tester.enterText(
          find.widgetWithText(TextField, '正文'),
          '今天读完了一本关于习惯的书。',
        );
        await tester.runAsync(() async {
          await tester.tap(find.text('保存文字'));
          await Future<void>.delayed(const Duration(milliseconds: 100));
        });
        await pumpUntil(tester, () => f.modelRequests.isNotEmpty);
        await pumpUntil(tester);

        expect(find.text('整理：已整理'), findsOneWidget);
        expect(find.text('记录想法'), findsWidgets);
        expect(f.modelRequests, hasLength(1));
        expect(f.workerPaths.where((p) => p.startsWith('/v1/budget')), isEmpty);
        await tester.pumpWidget(const SizedBox());
      }, _LoopbackHttpOverrides());
    },
  );
}
