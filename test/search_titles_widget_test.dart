import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/main.dart';
import 'package:note_agent/note_workspace.dart';

void main() {
  testWidgets(
    'find original and source, then edit a title without a duplicate dialog',
    (tester) async {
      final setup = await tester.runAsync(() async {
        final temporary = await Directory.systemTemp.createTemp(
          'note-agent-t04-ui-',
        );
        final vault = await Directory('${temporary.path}/vault').create();
        var id = 0;
        final workspace = await NoteWorkspace.open(
          localDirectory: Directory('${temporary.path}/local'),
          vaultDirectory: vault,
          createId: () => 'ui-${++id}',
        );
        await workspace.captureText(title: '会议', text: '原始记录：离线也能找回。');
        await workspace.captureText(title: '其他记录', text: '检索之外的内容。');
        return (temporary, workspace);
      });
      final (temporary, workspace) = setup!;
      addTearDown(() async {
        await workspace.close();
        await temporary.delete(recursive: true);
      });
      tester.view.physicalSize = const Size(1280, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      String? openedSource;
      const channel = MethodChannel('dev.noteagent/workspace');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'openInObsidian') {
          openedSource = (call.arguments as Map)['path'] as String;
        }
        return null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      await tester.pumpWidget(NoteAgentApp(initialWorkspace: workspace));
      await tester.enterText(find.widgetWithText(TextField, '搜索笔记'), '离线');
      await tester.pumpAndSettle();
      expect(find.text('其他记录'), findsNothing);
      await tester.tap(find.text('会议'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('原始文字'));
      await tester.pumpAndSettle();
      expect(find.text('收集的原文'), findsOneWidget);
      await tester.tap(find.text('打开来源文件'));
      await tester.pumpAndSettle();
      expect(openedSource, workspace.search('离线').single.sourcePath);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, '标题'), '其他记录');
      await tester.runAsync(() async {
        await tester.tap(find.text('保存标题'));
        for (var attempt = 0; attempt < 200; attempt++) {
          if (workspace.search('离线').single.title == '其他记录 (2)') return;
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        fail('Title edit did not finish.');
      });
      await tester.pumpAndSettle();
      expect(workspace.search('离线').single.titleCollision, isTrue);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('其他记录 (2)'), findsNWidgets(2));
      expect(find.text('摘要'), findsNothing);
      expect(find.text('属性'), findsNothing);
    },
  );
}
