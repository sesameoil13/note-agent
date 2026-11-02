import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/main.dart';

import 'audio_queue_test.dart' show wave;
import 'support/ai_fixture.dart';
import 'support/async_settle.dart';

class _LoopbackHttpOverrides extends HttpOverrides {}

/// 整理 (GLOSSARY) happens once: no note offers to organize it again, and a
/// transcript correction is a local edit only.
void main() {
  testWidgets(
    'an organized note offers no re-organize, preview or estimate, and a transcript correction sends nothing',
    (tester) async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final f = AiFixture();
        await tester.runAsync(() async {
          await f.start(devices: 1);
          final w = f.workspaces.first;
          f.modelResult = {
            'manifestVersion': 3,
            'kind': 'ordinary',
            'title': '读书笔记',
            'body': '整理后的读书笔记。',
            'actions': [],
            'associations': [],
            'newTopics': [],
          };
          await w.captureText(title: '读书', text: '今天读完了一本关于习惯的书。');
          await w.sendWaitingNow();
          f.modelResult = null;
          f.now = f.now.add(const Duration(minutes: 1));
          await w.importAudio(
            original: await File('${f.root.path}/a.wav').writeAsBytes(wave()),
            submissionId: 'no-reorganize-ui',
          );
          await w.sendWaitingNow();
        });
        addTearDown(() => tester.runAsync(f.close));
        tester.view.physicalSize = const Size(1280, 1100);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final w = f.workspaces.first;
        await tester.pumpWidget(NoteAgentApp(initialWorkspace: w));
        await pumpUntil(tester);

        void expectNoReorganizing() {
          for (final wording in ['重新整理', '重新预估', '再次预估', '预览', '仅整理']) {
            expect(find.textContaining(wording), findsNothing, reason: wording);
          }
        }

        await tester.tap(find.text('记录想法'));
        await pumpUntil(tester);
        expect(find.text('整理：已整理'), findsOneWidget);
        expectNoReorganizing();
        await tester.tap(find.text('更正转写'));
        await pumpUntil(tester);
        expectNoReorganizing();
        await tester.enterText(
          find.byKey(const ValueKey('transcript-correction')),
          '更正后的完整转写。',
        );
        await tester.runAsync(() async {
          await tester.tap(find.text('保存转写更正（不调用模型）'));
          await Future<void>.delayed(const Duration(milliseconds: 100));
        });
        await pumpUntil(
          tester,
          () => w.notes.first.originalText == '更正后的完整转写。',
        );
        expect(find.text('转写更正已保存。'), findsOneWidget);
        expectNoReorganizing();
        await tester.pageBack();
        await pumpUntil(tester);

        // A typed note has no transcript to correct.
        await tester.tap(find.text('读书笔记').first);
        await pumpUntil(tester);
        expect(find.text('整理：已整理'), findsOneWidget);
        expect(find.text('更正转写'), findsNothing);
        expectNoReorganizing();

        await tester.runAsync(w.sendWaitingNow);
        expect(f.modelRequests, hasLength(2));
        expect(f.audioRequests, hasLength(1));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      }, _LoopbackHttpOverrides());
    },
  );
}
