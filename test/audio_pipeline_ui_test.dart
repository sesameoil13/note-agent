import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/budget_panel.dart';

import 'audio_queue_test.dart' show wave;
import 'support/budget_fixture.dart';
import 'support/async_settle.dart';

class _LoopbackHttpOverrides extends HttpOverrides {}

void main() {
  testWidgets(
    'phone pipeline offers one informed consent for both stages and cancellation uploads nothing',
    (tester) async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final f = BudgetFixture();
        await tester.runAsync(() async {
          await f.start();
          await f.workspaces.first.importAudio(
            original: await File('${f.root.path}/synthetic.wav')
                .writeAsBytes(wave()),
            submissionId: 'ui-consent',
          );
        });
        addTearDown(() => tester.runAsync(f.close));
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(home: BudgetPanel(workspace: f.workspaces.first)),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await pumpUntil(tester);
        await tester.pumpAndSettle();
        final estimate = find.text('预估转写及整理（不上传）');
        await tester.scrollUntilVisible(
          estimate,
          300,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.runAsync(() async {
          await tester.tap(estimate);
          await Future<void>.delayed(const Duration(milliseconds: 100));
        });
        await pumpUntil(tester);
        await tester.pumpAndSettle();
        expect(f.audioRequests, 0);
        expect(f.modelRequests, isEmpty);
        expect(find.textContaining('不保证远端价格封顶'), findsOneWidget);
        expect(find.textContaining('20000'), findsOneWidget);
        await tester.scrollUntilVisible(
          find.text('确认上传并转写整理（两阶段可能计费）'),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text('确认上传并转写整理（两阶段可能计费）'), findsOneWidget);
        final cancel = find.text('取消未上传任务');
        await tester.scrollUntilVisible(
          cancel,
          150,
          scrollable: find.byType(Scrollable).first,
        );
        await pumpUntil(tester);
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          await tester.tap(cancel);
          await Future<void>.delayed(const Duration(milliseconds: 100));
        });
        await pumpUntil(tester);
        await tester.pumpAndSettle();
        expect(f.audioRequests, 0);
        expect(f.modelRequests, isEmpty);
        expect(f.workspaces.first.budget.reservedCnyMicros, 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      }, _LoopbackHttpOverrides());
    },
  );
}
