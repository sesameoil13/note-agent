import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/main.dart';
import 'package:note_agent/budget_panel.dart';
import 'package:note_agent/note_workspace.dart';

import 'audio_queue_test.dart' show wave;
import 'support/async_settle.dart';
import 'support/budget_fixture.dart';

class _LoopbackHttpOverrides extends HttpOverrides {}

void main() {
  for (final width in [360.0, 800.0]) {
    testWidgets(
      'compact app navigation reaches audio budgeting without uploading ($width)',
      (tester) async {
        await HttpOverrides.runWithHttpOverrides(() async {
          final f = BudgetFixture();
          await tester.runAsync(() async {
            await f.start();
            await f.workspaces.first.importAudio(
              original: await File('${f.root.path}/synthetic.wav')
                  .writeAsBytes(wave()),
              submissionId: 'compact-budget',
            );
          });
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
          final estimate = find.text('预估转写及整理（不上传）');
          await tester.scrollUntilVisible(
            estimate,
            300,
            scrollable: find
                .descendant(
                  of: find.byType(ListView),
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          await tester.runAsync(() async {
            await tester.tap(estimate);
            await Future<void>.delayed(const Duration(milliseconds: 100));
          });
          await pumpUntil(
            tester,
            () =>
                f.workspaces.first.audioJobs.isNotEmpty &&
                f.workspaces.first.audioJobs.single.status ==
                    AudioJobStatus.prepared,
          );
          // The panel's busy indicator ends only after its refresh.
          await pumpUntil(
            tester,
            () => find.byType(LinearProgressIndicator).evaluate().isEmpty,
            const Duration(seconds: 90),
          );
          await tester.pumpAndSettle();
          expect(
            f.workspaces.first.audioJobs.single.status,
            AudioJobStatus.prepared,
          );
          await tester.scrollUntilVisible(
            find.text('确认上传并转写整理（两阶段可能计费）'),
            200,
            scrollable: find
                .descendant(
                  of: find.byType(ListView),
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          expect(find.text('确认上传并转写整理（两阶段可能计费）'), findsOneWidget);
          final cancel = find.text('取消未上传任务');
          await tester.scrollUntilVisible(
            cancel,
            150,
            scrollable: find
                .descendant(
                  of: find.byType(ListView),
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          await tester.runAsync(() async {
            await tester.tap(cancel);
            await Future<void>.delayed(const Duration(milliseconds: 100));
          });
          await pumpUntil(
            tester,
            () => f.workspaces.first.budget.reservedCnyMicros == 0,
            const Duration(seconds: 90),
          );
          // The panel's busy indicator ends only after its refresh.
          await pumpUntil(
            tester,
            () => find.byType(LinearProgressIndicator).evaluate().isEmpty,
            const Duration(seconds: 90),
          );
          // Bounded settle: the assertions below decide the outcome, and a
          // frame that never stops is reported instead of hanging the test.
          await pumpUntil(tester);
          if (tester.binding.hasScheduledFrame) {
            debugPrint(
              'compact navigation still animating: '
              '${find.byType(ProgressIndicator).evaluate().map((e) => e.widget.runtimeType).toList()} '
              'job=${f.workspaces.first.audioJobs.map((j) => j.status).toList()}',
            );
          }
          expect(f.audioRequests, 0);
          expect(f.modelRequests, isEmpty);
          expect(f.workspaces.first.budget.reservedCnyMicros, 0);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        }, _LoopbackHttpOverrides());
      },
    );
  }
}
