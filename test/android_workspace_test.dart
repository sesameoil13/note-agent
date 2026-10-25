import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:note_agent/main.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/note_workspace.dart';
import 'package:note_agent/workspace_platform.dart';

import 'support/async_settle.dart';

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
            case 'vaultExists':
              return documents.containsKey(arguments!['relativePath']);
            case 'vaultListNotePaths':
              return documents.keys
                  .where((path) => path.toLowerCase().endsWith('.md'))
                  .toList();
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
  testWidgets(
    'Android permission failure and cancelled reauthorization retain the draft and retry one capture',
    (tester) async {
      final temporary = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('note-agent-phone-'),
      ))!;
      addTearDown(() => temporary.delete(recursive: true));
      tester.view.physicalSize = const Size(412, 892);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const tree =
          'content://com.android.externalstorage.documents/tree/primary%3ATestVault';
      var granted = false;
      var cancelPicker = false;
      final documents = <String, String>{};
      final location = <String, String>{
        'localDirectory': temporary.path,
        'vaultUri': tree,
        'vaultName': 'TestVault',
        'deviceInfo': 'Xiaomi · Android 16 · API 36',
      };
      const channel = MethodChannel('dev.noteagent/workspace');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method.startsWith('vault') && !granted) {
              throw PlatformException(
                code: 'directory_access',
                message: '笔记库授权已失效，请重新选择同一目录。',
              );
            }
            final arguments = call.arguments as Map?;
            switch (call.method) {
              case 'vaultExists':
                return documents.containsKey(arguments!['relativePath']);
              case 'vaultReadText':
                return documents[arguments!['relativePath'] as String];
              case 'vaultListNotePaths':
                return documents.keys
                    .where((path) => path.toLowerCase().endsWith('.md'))
                    .toList();
              case 'restoreLocation':
                return {'localDirectory': temporary.path};
              case 'chooseLocation':
                return cancelPicker ? null : location;
              case 'vaultPublishText':
                final args = call.arguments as Map;
                documents[args['relativePath'] as String] =
                    args['text'] as String;
                return null;
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
      await tester.pumpWidget(const NoteAgentApp());
      await pumpUntil(tester);
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.text('先选择本地笔记库'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await pumpUntil(tester);
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, '正文'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.enterText(find.widgetWithText(TextField, '标题'), '手机原文');
      await tester.enterText(
        find.widgetWithText(TextField, '正文'),
        '拒绝授权后仍保留中文。',
      );
      await tester.ensureVisible(find.text('保存文字'));
      await tester.runAsync(() async {
        await tester.tap(find.text('保存文字'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await pumpUntil(tester);
      await tester.pumpAndSettle();
      expect(find.text('拒绝授权后仍保留中文。'), findsOneWidget);
      expect(find.textContaining('授权已失效'), findsOneWidget);
      expect(find.text('本机已保存'), findsNothing);
      cancelPicker = true;
      await tester.tap(find.text('选择笔记库'));
      await pumpUntil(tester);
      await tester.pumpAndSettle();
      expect(find.text('拒绝授权后仍保留中文。'), findsOneWidget);
      cancelPicker = false;
      granted = true;
      await tester.runAsync(() async {
        await tester.tap(find.text('选择笔记库'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await pumpUntil(tester);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('保存文字'));
      await tester.runAsync(() async {
        await tester.tap(find.text('保存文字'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await pumpUntil(tester);
      await tester.pumpAndSettle();
      expect(find.text('本机已保存'), findsOneWidget);
      expect(
        documents.keys.where((name) => name.endsWith('.txt')),
        hasLength(1),
      );
      await tester.pumpWidget(const SizedBox());
      final workspace = (await tester.runAsync(
        () => NoteWorkspace.open(
          localDirectory: temporary,
          vaultStorage: AndroidVaultStorage(tree, 'TestVault'),
        ),
      ))!;
      expect(workspace.notes, hasLength(1));
      expect(workspace.notes.single.text, '拒绝授权后仍保留中文。');
      await workspace.close();
    },
  );
}
