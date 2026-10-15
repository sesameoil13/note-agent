import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/note_workspace.dart';

void main() {
  test('local publication and restart never claim official cloud acknowledgement', () async {
    final temporary = await Directory.systemTemp.createTemp('note-agent-sync-');
    final vault = await Directory('${temporary.path}/vault').create();
    final local = Directory('${temporary.path}/local');
    addTearDown(() => temporary.delete(recursive: true));
    var workspace = await NoteWorkspace.open(
      localDirectory: local,
      vaultDirectory: vault,
      createId: () => 'sync-unknown',
    );
    final saved = await workspace.captureText(title: '原文仍在本机', text: '等 Obsidian 运行后同步。');
    expect(saved.status, NoteStatus.localSaved);
    expect(saved.syncStatus, NoteSyncStatus.unverified);
    expect(workspace.taskStatusSync, TaskStatusSync.notConnected);
    await workspace.close();
    workspace = await NoteWorkspace.open(localDirectory: local, vaultDirectory: vault);
    addTearDown(workspace.close);
    expect(workspace.notes.single.syncStatus, NoteSyncStatus.unverified);
    expect(await File(saved.notePath).exists(), isTrue);
  });
  test('local vault estimate never stands in for available account storage', () async {
    final temporary = await Directory.systemTemp.createTemp('note-agent-capacity-');
    addTearDown(() => temporary.delete(recursive: true));
    final vault = await Directory('${temporary.path}/vault').create();
    final large = await File('${vault.path}/existing.bin').open(mode: FileMode.write);
    await large.truncate(1000000001);
    await large.close();
    final workspace = await NoteWorkspace.open(
      localDirectory: Directory('${temporary.path}/local'),
      vaultDirectory: vault,
    );
    addTearDown(workspace.close);
    final storage = await workspace.inspectSyncStorage();
    expect(storage.localVaultBytes, 1000000001);
    expect(storage.localVaultExceedsAccountLimit, isTrue);
    expect(storage.remoteUsedBytes, isNull);
    expect(storage.maximumFileBytes, 5000000);
    expect(storage.accountStorageBytes, 1000000000);
  });

}
