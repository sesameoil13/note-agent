import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:note_agent/main.dart';
import 'package:note_agent/note_workspace.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('native clipboard text becomes a durable ordinary note', (
    tester,
  ) async {
    final previousClipboard = await Clipboard.getData(Clipboard.kTextPlain);
    final temporary = await Directory.systemTemp.createTemp(
      'note-agent-native-',
    );
    final local = Directory('${temporary.path}/local');
    final vault = await Directory('${temporary.path}/vault').create();
    var workspace = await NoteWorkspace.open(
      localDirectory: local,
      vaultDirectory: vault,
      createId: () => 'native-clipboard',
      clock: () => DateTime(2026, 10, 15, 18, 0),
    );
    addTearDown(() async {
      await workspace.close();
      await temporary.delete(recursive: true);
      await Clipboard.setData(
        previousClipboard ?? const ClipboardData(text: ''),
      );
    });
    await tester.pumpWidget(NoteAgentApp(initialWorkspace: workspace));
    await tester.pumpAndSettle();

    Future<void> pasteInto(Finder field, String text) async {
      await Clipboard.setData(ClipboardData(text: text));
      expect((await Clipboard.getData(Clipboard.kTextPlain))?.text, text);
      await tester.tap(field);
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();
      expect(find.text(text), findsOneWidget);
    }

    await pasteInto(find.widgetWithText(TextField, '标题'), '原生粘贴验收');
    const original = '普通笔记应保留完整原文。\n这是一条用于验证粘贴与重启恢复的测试记录。';
    await pasteInto(find.widgetWithText(TextField, '正文'), original);
    await tester.ensureVisible(find.text('保存文字'));
    await tester.tap(find.text('保存文字'));
    for (var attempt = 0; attempt < 100; attempt++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (workspace.notes.isNotEmpty &&
          workspace.notes.single.status == NoteStatus.localSaved) {
        break;
      }
    }
    expect(workspace.notes.single.title, '原生粘贴验收');
    expect(workspace.notes.single.text, original);
    expect(workspace.notes.single.status, NoteStatus.localSaved);
    final notePath = workspace.notes.single.notePath;
    final sourcePath = workspace.notes.single.sourcePath;
    expect(await File(sourcePath).readAsString(), original);
    expect(await File(notePath).readAsString(), contains('## 正文\n\n$original'));
    expect(await File(notePath).readAsString(), isNot(contains('## 摘要')));

    await tester.pumpWidget(const SizedBox());
    await workspace.close();
    workspace = await NoteWorkspace.open(
      localDirectory: local,
      vaultDirectory: vault,
    );
    expect(workspace.notes.single.title, '原生粘贴验收');
    expect(workspace.notes.single.text, original);
    expect(workspace.notes.single.status, NoteStatus.localSaved);
  });
}
