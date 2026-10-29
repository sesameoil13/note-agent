import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/note_workspace.dart';
import 'package:note_agent/recording_panel.dart';

import 'audio_queue_test.dart' show wave;
import 'support/ai_fixture.dart';
import 'support/async_settle.dart';

class _LoopbackHttpOverrides extends HttpOverrides {}

void main() {
  testWidgets(
    'imported audio shows its 整理 status, and a failed one offers 重试',
    (tester) async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final f = AiFixture()..audioStatuses.add(503);
        late WorkspaceAudioSource source;
        await tester.runAsync(() async {
          await f.start(devices: 1);
          source = await f.workspaces.first.importAudio(
            original: await File('${f.root.path}/memo.wav')
                .writeAsBytes(wave(seconds: 4)),
            submissionId: 'ui-audio',
          );
        });
        addTearDown(() => tester.runAsync(f.close));
        final w = f.workspaces.first;
        tester.view.physicalSize = const Size(1280, 1100);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: RecordingPanel(workspace: w)),
          ),
        );
        await pumpUntil(tester);
        expect(find.text('整理：等待发送'), findsOneWidget);
        expect(find.textContaining('预估'), findsNothing);

        await tester.runAsync(w.sendWaitingNow);
        await pumpUntil(tester, () => find.text('整理：失败').evaluate().isNotEmpty);
        expect(find.text('整理：失败'), findsOneWidget);

        await tester.runAsync(() async {
          await tester.tap(find.text('重试'));
          await Future<void>.delayed(const Duration(milliseconds: 100));
        });
        await pumpUntil(
          tester,
          () => find.text('整理：已整理').evaluate().isNotEmpty,
        );
        expect(find.text('整理：已整理'), findsOneWidget);
        expect(w.organizeStatus(source.outputNoteId), OrganizeStatus.organized);
        expect(f.audioRequests, hasLength(2));
        expect(f.modelRequests, hasLength(1));
        expect(f.workerPaths.where((p) => p.startsWith('/v1/budget')), isEmpty);
        await tester.pumpWidget(const SizedBox());
      }, _LoopbackHttpOverrides());
    },
  );
}
