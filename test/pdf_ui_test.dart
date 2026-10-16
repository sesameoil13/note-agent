import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/main.dart';
import 'package:note_agent/note_workspace.dart';

void main() {
  testWidgets(
    'PDF picker cancellation and import show a normal note with accurately named extraction results',
    (tester) async {
      final setup = await tester.runAsync(() async {
        final root = await Directory.systemTemp.createTemp('pdf-ui-');
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
      const channel = MethodChannel('dev.noteagent/workspace');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'chooseSourceFile') return selected;
        if (call.method == 'releaseSourceFile') return null;
        throw PlatformException(code: 'unexpected', message: call.method);
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      await tester.pumpWidget(NoteAgentApp(initialWorkspace: workspace));
      await tester.tap(find.text('导入 PDF'));
      await tester.pumpAndSettle();
      expect(workspace.notes, isEmpty);
      selected = File('test/fixtures/chinese.pdf').absolute.path;
      await tester.runAsync(() async {
        await tester.tap(find.text('导入 PDF'));
        for (var attempt = 0; attempt < 400; attempt++) {
          if (workspace.notes.firstOrNull?.document?.status ==
              DocumentImportStatus.ready) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
            return;
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        fail('PDF import did not finish.');
      });
      await tester.pumpAndSettle();
      expect(find.text('正文'), findsOneWidget);
      expect(find.text('关联'), findsOneWidget);
      expect(find.text('来源'), findsOneWidget);
      expect(find.text('摘要'), findsNothing);
      expect(find.textContaining('已提取文字及可识别的规则表格'), findsOneWidget);
      await tester.ensureVisible(find.text('提取结果'));
      await tester.tap(find.text('提取结果'));
      await tester.pumpAndSettle();
      expect(find.text('PDF 提取结果'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
