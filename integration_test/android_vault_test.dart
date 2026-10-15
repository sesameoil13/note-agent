import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:note_agent/note_workspace.dart';
import 'package:note_agent/workspace_platform.dart';

/// Run only after choosing a dedicated, new test vault in the installed app.
/// This validates real SAF I/O; reboot/picker/revocation/Obsidian still need the
/// separate human acceptance checklist. A host/mock run is not phone evidence.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'authorized Android provider publishes and restores an ordinary note',
    (tester) async {
      const expectedVault = String.fromEnvironment('ANDROID_TEST_VAULT_NAME');
      expect(
        expectedVault,
        startsWith('NoteAgent-Test-'),
        reason: 'Pass the exact dedicated test-vault name; existing personal vaults are off limits.',
      );
      final platform = WorkspacePlatform();
      final location = await platform.restoreLocation();
      final storage = location.vaultStorage!;
      expect(storage.displayName, expectedVault);
      expect(location.authorizationError, isNull);
      expect(location.deviceInfo, contains('Android'));
      // Captured from Build on this device, never a hard-coded target version.
      // ignore: avoid_print
      print('Android device under test: ${location.deviceInfo}');
      final id = 'android-acceptance-${DateTime.now().microsecondsSinceEpoch}';
      var workspace = await NoteWorkspace.open(
        localDirectory: Directory('${location.localDirectory.path}/$id'),
        vaultStorage: storage,
        createId: () => id,
        clock: () => DateTime(2026, 10, 15, 9, 30),
      );
      final note = await workspace.captureText(
        title: '手机文字验收$id',
        text: '通过系统授权保存中文原文。\n保留第二行。\n',
      );
      expect(note.status, NoteStatus.localSaved, reason: note.error);
      expect(
        await storage.readText(storage.relativePath(note.sourcePath)),
        '通过系统授权保存中文原文。\n保留第二行。\n',
      );
      final markdown = await storage.readText(
        storage.relativePath(note.notePath),
      );
      expect(
        markdown,
        contains('## 正文\n\n通过系统授权保存中文原文。\n保留第二行。\n\n## 关联\n\n暂无关联\n\n## 来源'),
      );
      expect(markdown, isNot(contains('## 摘要')));
      expect(
        markdown,
        endsWith('记录：2026-10-15 09:30:00 · 修改：2026-10-15 09:30:00\n'),
      );
      await workspace.close();
      final restored = await platform.restoreLocation();
      expect(restored.vaultStorage!.identity, storage.identity);
      workspace = await NoteWorkspace.open(
        localDirectory: Directory('${restored.localDirectory.path}/$id'),
        vaultStorage: restored.vaultStorage,
      );
      expect(workspace.notes.single.text, '通过系统授权保存中文原文。\n保留第二行。\n');
      expect(workspace.notes.single.status, NoteStatus.localSaved);
      await workspace.close();
    },
    skip: !Platform.isAndroid,
  );
}
