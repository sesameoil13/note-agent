import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/note_workspace.dart';

void main() {
  test('remote slot consent requires a verified backup and retained local import copy', () async {
    final root = await Directory.systemTemp.createTemp('setup-workspace-');
    addTearDown(() => root.delete(recursive: true));
    final workspace = await NoteWorkspace.open(
      localDirectory: Directory('${root.path}/local'),
      vaultDirectory: await Directory('${root.path}/new').create(),
    );
    addTearDown(workspace.close);
    expect(workspace.setup.remoteSlotConsentAt, isNull);
    await expectLater(workspace.confirmRemoteSlotSwitch(), throwsStateError);
    await workspace.reportSetupCheck(SetupCheck.backupComplete, true);
    await expectLater(workspace.confirmRemoteSlotSwitch(), throwsStateError);
    await workspace.reportSetupCheck(SetupCheck.localImportCopyRetained, true);
    await workspace.confirmRemoteSlotSwitch();
    expect(workspace.setup.remoteSlotConsentAt, isNotNull);
    expect(workspace.setup.isReported(SetupCheck.remoteSlotSwitched), isFalse);
    expect(workspace.setup.noteSyncVerified, isFalse);
  });
  test('reports restore only for their vault and can be cleared without changing notes or backup files', () async {
    final root = await Directory.systemTemp.createTemp('setup-restore-');
    addTearDown(() => root.delete(recursive: true));
    final local = Directory('${root.path}/local');
    final vault = await Directory('${root.path}/new').create();
    final backup = await File('${root.path}/old-backup.md')
        .writeAsString('旧库原文');
    var workspace = await NoteWorkspace.open(
      localDirectory: local,
      vaultDirectory: vault,
    );
    final note = await workspace.captureText(title: '新想法', text: '保留输入和原文');
    await workspace.reportSetupCheck(SetupCheck.correctVaultOpened, true);
    await workspace.reportSetupCheck(SetupCheck.backupComplete, true);
    await workspace.reportSetupCheck(SetupCheck.localImportCopyRetained, true);
    await workspace.confirmRemoteSlotSwitch();
    await workspace.close();
    workspace = await NoteWorkspace.open(
      localDirectory: local,
      vaultDirectory: vault,
    );
    expect(workspace.setup.isReported(SetupCheck.correctVaultOpened), isTrue);
    expect(workspace.setup.remoteSlotConsentAt, isNotNull);
    await workspace.close();
    final other = await NoteWorkspace.open(
      localDirectory: local,
      vaultDirectory: await Directory('${root.path}/other').create(),
    );
    expect(other.setup.reports, isEmpty);
    expect(other.setup.remoteSlotConsentAt, isNull);
    await other.close();
    workspace = await NoteWorkspace.open(
      localDirectory: local,
      vaultDirectory: vault,
    );
    addTearDown(workspace.close);
    await workspace.clearSetupReports();
    expect(workspace.setup.reports, isEmpty);
    expect(workspace.setup.remoteSlotConsentAt, isNull);
    expect(workspace.notes.single.id, note.id);
    expect(workspace.notes.single.originalText, '保留输入和原文');
    expect(await backup.readAsString(), '旧库原文');
    expect(await File(note.notePath).readAsString(), contains('保留输入和原文'));
  });
}
