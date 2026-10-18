import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/main.dart';
import 'package:note_agent/note_workspace.dart';

void main() {
  testWidgets(
    'Word picker cancellation and import show a normal note with accurately named extraction results',
    (tester) async {
      final setup = await tester.runAsync(() async {
        final root = await Directory.systemTemp.createTemp('word-ui-');
        final vault = await Directory('${root.path}/vault').create();
        final workspace = await NoteWorkspace.open(
          localDirectory: Directory('${root.path}/local'),
          vaultDirectory: vault,
        );
        return (root, workspace);
      });
      final (root, workspace) = setup!;
      addTearDown(() async {
        await workspace.close();
        await root.delete(recursive: true);
      });
      tester.view.physicalSize = const Size(1280, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      String? selected;
      final sourceReleased = Completer<void>();
      const channel = MethodChannel('dev.noteagent/workspace');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'chooseSourceFile') {
          expect((call.arguments as Map)['wordOnly'], isTrue);
          return selected;
        }
        if (call.method == 'releaseSourceFile') {
          sourceReleased.complete();
          return null;
        }
        throw PlatformException(code: 'unexpected', message: call.method);
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      await tester.pumpWidget(NoteAgentApp(initialWorkspace: workspace));
      await tester.tap(find.text('导入 Word'));
      await tester.pumpAndSettle();
      expect(workspace.notes, isEmpty);
      selected = File('test/fixtures/word/body-table.docx').absolute.path;
      await tester.runAsync(() => tester.tap(find.text('导入 Word')));
      // The grant is released after publication and note selection. Pump the
      // widget/channel event loop until that boundary, not just DB readiness.
      final elapsed = Stopwatch()..start();
      while (!sourceReleased.isCompleted) {
        if (elapsed.elapsed > const Duration(seconds: 20)) {
          fail('PDF import did not release its selected source.');
        }
        await tester.pump(const Duration(milliseconds: 16));
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      }
      await tester.pumpAndSettle();
      expect(find.text('正在导入 Word…'), findsNothing);
      expect(find.text('正文'), findsOneWidget);
      expect(find.text('关联'), findsOneWidget);
      expect(find.text('来源'), findsOneWidget);
      expect(find.text('摘要'), findsNothing);
      expect(find.textContaining('已提取文字及可提取表格'), findsOneWidget);
      await tester.ensureVisible(find.text('提取结果'));
      await tester.tap(find.text('提取结果'));
      await tester.pumpAndSettle();
      expect(find.text('Word 提取结果'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
