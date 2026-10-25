import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/main.dart';
import 'package:note_agent/note_workspace.dart';

void main() {
  testWidgets(
    'attachment choices use a selected smaller copy and keep sync status honest',
    (tester) async {
      final setup = await tester.runAsync(() async {
        final temporary = await Directory.systemTemp.createTemp(
          'note-agent-sync-ui-',
        );
        final vault = await Directory('${temporary.path}/vault').create();
        var sequence = 0;
        final workspace = await NoteWorkspace.open(
          localDirectory: Directory('${temporary.path}/local'),
          vaultDirectory: vault,
          createId: () => 'ui-source-${sequence++}',
        );
        final note = await workspace.captureText(
          title: '采访来源',
          text: '保存原件后再决定。',
        );
        final original = await File('${temporary.path}/完整采访.m4a')
            .writeAsBytes(List<int>.filled(5000001, 3));
        await workspace.attachFile(noteId: note.id, original: original);
        final copy = await File('${temporary.path}/采访精简.m4a')
            .writeAsBytes([1, 2, 3]);
        return (temporary, workspace, copy);
      });
      final (temporary, workspace, copy) = setup!;
      addTearDown(() async {
        await workspace.close();
        await temporary.delete(recursive: true);
      });
      const channel = MethodChannel('dev.noteagent/workspace');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'chooseSourceFile') return copy.path;
        if (call.method == 'releaseSourceFile') return null;
        throw PlatformException(code: 'unexpected', message: call.method);
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      tester.view.physicalSize = const Size(1280, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(NoteAgentApp(initialWorkspace: workspace));
      await tester.tap(find.text('采访来源'));
      await tester.pumpAndSettle();
      expect(find.text('笔记同步：尚未核实'), findsOneWidget);
      expect(find.text('待办状态同步：尚未连接'), findsOneWidget);
      await tester.ensureVisible(find.text('处理附件'));
      await tester.tap(find.text('处理附件'));
      await tester.pumpAndSettle();
      expect(find.text('仅保留本机'), findsOneWidget);
      expect(find.text('套餐与容量说明'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.text('选择精简副本'));
        for (var attempt = 0; attempt < 200; attempt++) {
          if (workspace.attachments.single.copyName != null &&
              workspace.attachments.single.status ==
                  AttachmentStatus.localSaved) {
            return;
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        fail('The selected copy did not finish publication.');
      });
      await tester.pumpAndSettle();
      expect(find.textContaining('原件仅本机，未同步'), findsWidgets);
      expect(find.textContaining('全端同步完成'), findsNothing);
      await tester.runAsync(() async {
        expect(
          await File(workspace.attachments.single.originalPath).length(),
          5000001,
        );
        expect(
          await File(workspace.attachments.single.sourcePath).readAsBytes(),
          [1, 2, 3],
        );
      });
    },
  );
}
