import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/note_workspace.dart';

/// All "old vaults" here are synthetic temporary directories; the App never
/// discovers a real vault on its own.
Future<Map<String, String>> _snapshot(Directory dir) async => {
  for (final entity in dir.listSync(recursive: true))
    if (entity is File)
      entity.path.substring(dir.path.length): await entity.readAsString(),
};

void main() {
  late Directory root;
  late NoteWorkspace workspace;
  late Directory oldVault;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('backup-check-');
    workspace = await NoteWorkspace.open(
      localDirectory: Directory('${root.path}/local'),
      vaultDirectory: await Directory('${root.path}/new').create(),
    );
    oldVault = Directory('${root.path}/old');
    await File('${oldVault.path}/日记.md').create(recursive: true);
    await File('${oldVault.path}/日记.md').writeAsString('旧库原文');
    await File('${oldVault.path}/附件/图.png').create(recursive: true);
    await File('${oldVault.path}/附件/图.png').writeAsString('png-bytes');
    await File('${oldVault.path}/.obsidian/app.json').create(recursive: true);
    await File('${oldVault.path}/.obsidian/app.json').writeAsString('{}');
  });
  tearDown(() async {
    await workspace.close();
    await root.delete(recursive: true);
  });

  Future<Directory> copyOld(String name) async {
    final target = Directory('${root.path}/$name');
    for (final entity in oldVault.listSync(recursive: true)) {
      if (entity is! File) continue;
      final dest = File(
        '${target.path}${entity.path.substring(oldVault.path.length)}',
      );
      await dest.create(recursive: true);
      await entity.copy(dest.path);
    }
    return target;
  }

  test('a complete separate backup is verified by the App without changing either folder', () async {
    final backup = await copyOld('backup');
    final before = await _snapshot(oldVault);
    final result = await workspace.checkOldVaultBackup(
      oldVault: oldVault,
      backup: backup,
    );
    expect(result.complete, isTrue);
    expect(result.oldFileCount, 3);
    expect(result.backupFileCount, 3);
    expect(result.oldBytes, 23); // 12 UTF-8 bytes + 9 + 2
    expect(result.includesObsidianConfig, isTrue);
    expect(result.missing, isEmpty);
    expect(workspace.setup.backupVerifiedAt, isNotNull);
    expect(
      workspace.setup.backupReady,
      isFalse,
      reason: 'the retained local import copy is still the user\'s report',
    );
    await workspace.reportSetupCheck(SetupCheck.localImportCopyRetained, true);
    expect(workspace.setup.backupReady, isTrue);
    expect(await _snapshot(oldVault), before);
    expect(await _snapshot(backup), before);
  });

  test('an incomplete backup is shown with its gaps and invalidates earlier consent', () async {
    final backup = await copyOld('backup');
    await workspace.checkOldVaultBackup(oldVault: oldVault, backup: backup);
    await workspace.reportSetupCheck(SetupCheck.localImportCopyRetained, true);
    await workspace.confirmRemoteSlotSwitch();
    expect(workspace.setup.remoteSlotConsentAt, isNotNull);

    await File('${backup.path}/.obsidian/app.json').delete();
    await File('${backup.path}/附件/图.png').writeAsString('short');
    final result = await workspace.checkOldVaultBackup(
      oldVault: oldVault,
      backup: backup,
    );
    expect(result.complete, isFalse);
    expect(result.includesObsidianConfig, isFalse);
    expect(result.missing, ['.obsidian/app.json']);
    expect(result.sizeMismatched, ['附件/图.png']);
    expect(workspace.setup.backupVerifiedAt, isNull);
    expect(workspace.setup.remoteSlotConsentAt, isNull);
    expect(workspace.setup.backupReady, isFalse);
  });

  test('the backup must be a separate location outside the old vault and the sync vault', () async {
    final inside = await copyOld('old/备份');
    await expectLater(
      workspace.checkOldVaultBackup(oldVault: oldVault, backup: inside),
      throwsA(isA<BackupCheckRefused>()),
    );
    final newVault = Directory('${root.path}/new');
    await expectLater(
      workspace.checkOldVaultBackup(oldVault: newVault, backup: oldVault),
      throwsA(isA<BackupCheckRefused>()),
    );
    final inSync = await copyOld('new/备份');
    await expectLater(
      workspace.checkOldVaultBackup(oldVault: oldVault, backup: inSync),
      throwsA(isA<BackupCheckRefused>()),
    );
    await expectLater(
      workspace.checkOldVaultBackup(
        oldVault: Directory('${root.path}/empty')..createSync(),
        backup: await copyOld('backup'),
      ),
      throwsA(isA<BackupCheckRefused>()),
    );
    expect(workspace.setup.backupVerifiedAt, isNull);
  });
}
