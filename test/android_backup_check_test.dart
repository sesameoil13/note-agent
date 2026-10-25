import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/note_workspace.dart';
import 'package:note_agent/workspace_platform.dart';

/// Android's comparison goes through read-only SAF trees picked for one check.
/// The channel is the system boundary; every tree here is synthetic.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.noteagent/workspace');
  const syncTree =
      'content://com.android.externalstorage.documents/tree/primary%3ASyncVault';
  const oldTree =
      'content://com.android.externalstorage.documents/tree/primary%3AOldVault';
  const backupTree =
      'content://com.android.externalstorage.documents/tree/primary%3ABackups%2FOldVault';
  final oldFiles = {'日记.md': 12, '附件/图.png': 9, '.obsidian/app.json': 2};
  late Directory temporary;
  late List<MethodCall> calls;
  late List<String> picks;
  late Map<String, Map<String, int>> trees;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('android-backup-');
    calls = [];
    picks = [];
    trees = {oldTree: oldFiles, backupTree: Map.of(oldFiles)};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          final arguments = call.arguments as Map<Object?, Object?>?;
          switch (call.method) {
            case 'chooseFolder':
              return picks.removeAt(0);
            case 'readFolderInventory':
              return trees[arguments!['treeUri']];
            case 'vaultListNotePaths':
              return <String>[];
            case 'vaultExists':
              return false;
            default:
              return null;
          }
        });
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await temporary.delete(recursive: true);
  });

  Future<NoteWorkspace> openWorkspace() => NoteWorkspace.open(
    localDirectory: temporary,
    vaultStorage: AndroidVaultStorage(syncTree, 'SyncVault'),
  );

  test(
    'a complete backup tree is verified through read-only SAF picks',
    () async {
      final workspace = await openWorkspace();
      addTearDown(workspace.close);
      picks = [oldTree, backupTree];
      final platform = WorkspacePlatform();
      final old = (await platform.chooseFolderForReading('旧库'))!;
      final backup = (await platform.chooseFolderForReading('备份'))!;
      final result = await workspace.checkOldVaultBackupFolders(
        oldVault: old,
        backup: backup,
      );
      expect(result.complete, isTrue);
      expect(result.oldFileCount, 3);
      expect(result.oldBytes, 23);
      expect(result.includesObsidianConfig, isTrue);
      expect(workspace.setup.backupVerifiedAt, isNotNull);
      expect(
        calls
            .map((call) => call.method)
            .where(
              (method) =>
                  method != 'vaultListNotePaths' && method != 'vaultExists',
            ),
        [
          'chooseFolder',
          'chooseFolder',
          'readFolderInventory',
          'readFolderInventory',
        ],
        reason: 'neither tree is ever written',
      );
    },
  );

  test(
    'a backup tree with a missing file withdraws the App-verified record',
    () async {
      final workspace = await openWorkspace();
      addTearDown(workspace.close);
      trees[backupTree] = {'日记.md': 12, '.obsidian/app.json': 2};
      picks = [oldTree, backupTree];
      final platform = WorkspacePlatform();
      final result = await workspace.checkOldVaultBackupFolders(
        oldVault: (await platform.chooseFolderForReading('旧库'))!,
        backup: (await platform.chooseFolderForReading('备份'))!,
      );
      expect(result.complete, isFalse);
      expect(result.missing, ['附件/图.png']);
      expect(workspace.setup.backupVerifiedAt, isNull);
    },
  );

  test(
    'trees inside the old vault or the sync vault are refused before listing',
    () async {
      final workspace = await openWorkspace();
      addTearDown(workspace.close);
      final platform = WorkspacePlatform();
      Future<Object?> attempt(String old, String backup) async {
        picks = [old, backup];
        try {
          await workspace.checkOldVaultBackupFolders(
            oldVault: (await platform.chooseFolderForReading('旧库'))!,
            backup: (await platform.chooseFolderForReading('备份'))!,
          );
          return null;
        } on BackupCheckRefused catch (refused) {
          return refused.message;
        }
      }

      expect(
        await attempt(
          oldTree,
          'content://com.android.externalstorage.documents/tree/primary%3AOldVault%2Fcopy',
        ),
        contains('独立位置'),
      );
      expect(
        await attempt(
          'content://com.android.externalstorage.documents/tree/primary%3ASyncVault%2Fold',
          backupTree,
        ),
        contains('同步库'),
      );
      expect(
        await attempt(
          oldTree,
          'content://com.android.externalstorage.documents/tree/primary%3A',
        ),
        contains('独立位置'),
        reason: 'the whole volume contains the old vault',
      );
      expect(
        calls.where((call) => call.method == 'readFolderInventory'),
        isEmpty,
      );
    },
  );
}
