import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/note_workspace.dart';
import 'package:note_agent/workspace_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('authorized Android tree saves ordinary note and source and restores the same workspace', () async {
    final temporary = await Directory.systemTemp.createTemp('note-agent-saf-');
    addTearDown(() => temporary.delete(recursive: true));
    final documents = <String, String>{};
    const tree =
        'content://com.android.externalstorage.documents/tree/primary%3ATestVault';
    const channel = MethodChannel('dev.noteagent/workspace');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          final arguments = call.arguments as Map<Object?, Object?>?;
          switch (call.method) {
            case 'chooseLocation':
            case 'restoreLocation':
              return <String, String>{
                'localDirectory': temporary.path,
                'vaultUri': tree,
                'vaultName': 'TestVault',
                'deviceInfo': 'Xiaomi 17 Pro Max · Android 16 · API 36',
              };
            case 'vaultPublishText':
              documents[arguments!['relativePath']! as String] =
                  arguments['text']! as String;
              return null;
            case 'vaultReadText':
              return documents[arguments!['relativePath']! as String];
            default:
              throw PlatformException(
                code: 'unsupported',
                message: call.method,
              );
          }
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final location = (await WorkspacePlatform().chooseLocation())!;
    var workspace = await NoteWorkspace.open(
      localDirectory: location.localDirectory,
      vaultStorage: location.vaultStorage,
      clock: () => DateTime(2026, 10, 15, 9, 30),
      createId: () => 'android-capture',
    );
    final saved = await workspace.captureText(
      title: '手机上的想法',
      text: '完整中文原文。\n第二行。\n',
    );
    expect(saved.status, NoteStatus.localSaved);
    expect(
      await workspace.vaultStorage.readText(
        'attachments/note-agent/android-capture.txt',
      ),
      '完整中文原文。\n第二行。\n',
    );
    expect(await workspace.vaultStorage.readText('手机上的想法.md'), '''## 正文

完整中文原文。
第二行。

## 关联

暂无关联

## 来源

[原始文字](attachments/note-agent/android-capture.txt)

记录：2026-10-15 09:30:00 · 修改：2026-10-15 09:30:00
''');
    await workspace.close();
    final restored = await WorkspacePlatform().restoreLocation();
    workspace = await NoteWorkspace.open(
      localDirectory: restored.localDirectory,
      vaultStorage: restored.vaultStorage,
    );
    addTearDown(workspace.close);
    expect(workspace.notes.single.text, '完整中文原文。\n第二行。\n');
    expect(workspace.notes.single.status, NoteStatus.localSaved);
    expect(workspace.vaultStorage.identity, tree);
    expect(restored.deviceInfo, contains('Android 16'));
  });
}
