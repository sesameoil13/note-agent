import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/main.dart';
import 'package:note_agent/note_workspace.dart';

void main() {
  testWidgets('collecting text shows a saved ordinary note in list and detail', (
    tester,
  ) async {
    final setup = await tester.runAsync(() async {
      final temporary = await Directory.systemTemp.createTemp('note-agent-ui-');
      final vault = await Directory('${temporary.path}/test-vault').create();
      final workspace = await NoteWorkspace.open(
        localDirectory: Directory('${temporary.path}/local'),
        vaultDirectory: vault,
        createId: () => 'ui-capture',
      );
      return (temporary, workspace);
    });
    final (temporary, workspace) = setup!;
    addTearDown(() async {
      await workspace.close();
      await temporary.delete(recursive: true);
    });
    tester.view.physicalSize = const Size(1280, 960);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const visualOutput = String.fromEnvironment('VISUAL_OUTPUT');
    if (visualOutput.isNotEmpty) {
      const visualFont = String.fromEnvironment('VISUAL_FONT');
      const visualIcons = String.fromEnvironment('VISUAL_ICONS');
      if (visualFont.isEmpty || visualIcons.isEmpty) {
        fail('Supply VISUAL_FONT and VISUAL_ICONS with VISUAL_OUTPUT.');
      }
      await tester.runAsync(() async {
        final font = FontLoader('Roboto')
          ..addFont(File(visualFont).readAsBytes().then(ByteData.sublistView));
        await font.load();
        final mono = FontLoader('monospace')
          ..addFont(File(visualFont).readAsBytes().then(ByteData.sublistView));
        await mono.load();
        final icons = FontLoader('MaterialIcons')
          ..addFont(File(visualIcons).readAsBytes().then(ByteData.sublistView));
        await icons.load();
      });
    }
    await tester.pumpWidget(
      RepaintBoundary(
        key: const Key('workspace-visual'),
        child: NoteAgentApp(initialWorkspace: workspace),
      ),
    );
    await tester.enterText(find.widgetWithText(TextField, '标题'), '清晰阅读');
    await tester.enterText(
      find.widgetWithText(TextField, '正文'),
      '正文与图片始终保持清晰。',
    );
    if (visualOutput.isNotEmpty) {
      await tester.pumpAndSettle();
      await _capture(tester, '$visualOutput/t01-collection-widget.png');
    }
    await tester.runAsync(() async {
      await tester.tap(find.text('保存文字'));
      for (var attempt = 0; attempt < 200; attempt++) {
        if (workspace.notes.isNotEmpty &&
            workspace.notes.single.status == NoteStatus.localSaved) {
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      fail(
        'The capture did not finish writing: ${workspace.notes.map((note) => (note.status, note.error))}',
      );
    });
    await tester.pumpAndSettle();
    expect(find.text('清晰阅读'), findsNWidgets(2));
    expect(find.text('正文与图片始终保持清晰。'), findsWidgets);
    expect(find.text('本机已保存'), findsWidgets);
    expect(find.text('关联'), findsOneWidget);
    expect(find.text('来源'), findsOneWidget);
    expect(find.text('摘要'), findsNothing);
    expect(find.text('属性'), findsNothing);
    if (visualOutput.isNotEmpty) {
      await _capture(tester, '$visualOutput/t01-detail-widget.png');
    }
    await tester.tap(find.text('原始文字'));
    await tester.pumpAndSettle();
    expect(find.text('收集的原文'), findsOneWidget);
    expect(workspace.notes.single.id, 'ui-capture');
  });
}

Future<void> _capture(WidgetTester tester, String path) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const Key('workspace-visual')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await File(path).parent.create(recursive: true);
    await File(path).writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}
