import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/main.dart';
import 'package:note_agent/note_workspace.dart';

import 'audio_queue_test.dart' show wave;

void main() {
  testWidgets(
    'import action saves a private original before releasing source access and shows pending status',
    (tester) async {
      late Directory root;
      late File file;
      late NoteWorkspace workspace;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('note-agent-audio-ui-');
        file = await File('${root.path}/外部录音.wav')
            .writeAsBytes(wave(), flush: true);
        workspace = await NoteWorkspace.open(
          localDirectory: Directory('${root.path}/local'),
          vaultDirectory: await Directory('${root.path}/vault').create(),
        );
      });
      addTearDown(() => root.delete(recursive: true));
      addTearDown(workspace.close);
      const channel = MethodChannel('dev.noteagent/workspace');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'chooseSourceFile') {
          expect((call.arguments as Map)['audioOnly'], isTrue);
          return file.path;
        }
        if (call.method == 'releaseSourceFile') {
          // The OS grant can disappear immediately after release. Durability
          // must be observable in the workspace before this boundary returns.
          expect(workspace.audioSources.single.originalSaved, isTrue);
          expect(
            await File(workspace.audioSources.single.originalPath)
                .readAsBytes(),
            wave(),
          );
          await file.delete();
          return null;
        }
        throw MissingPluginException();
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(NoteAgentApp(initialWorkspace: workspace));
      await tester.tap(find.byTooltip('录音'));
      await tester.pump();
      await tester.tap(find.text('导入已有录音'));
      final importButton = find.widgetWithText(OutlinedButton, '导入已有录音');
      for (var i = 0; i < 200; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
        if (tester.widget<OutlinedButton>(importButton).onPressed != null &&
            workspace.audioSources.isNotEmpty) {
          break;
        }
      }
      expect(tester.widget<OutlinedButton>(importButton).onPressed, isNotNull);
      expect(await tester.runAsync(file.exists), isFalse);
      expect(
        workspace.audioSources.single.processingStatus,
        AudioProcessingStatus.pending,
      );
      expect(workspace.notes, isEmpty);
      // Queued for automatic 整理; nothing is sent without a key.
      expect(find.text('整理：等待发送'), findsOneWidget);
      expect(find.text('本机原音频已保存'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
