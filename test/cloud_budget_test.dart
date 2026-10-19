import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/note_workspace.dart';

void main() {
  test('disconnected budget does not block a locally saved original across restart', () async {
    final root = await Directory.systemTemp.createTemp('budget-local-');
    final vault = await Directory('${root.path}/vault').create();
    final local = Directory('${root.path}/local');
    var workspace = await NoteWorkspace.open(
      localDirectory: local,
      vaultDirectory: vault,
    );
    final note = await workspace.captureText(
      title: '离线想法',
      text: '先保存原文，连接后再整理。',
    );
    expect(workspace.budget.connected, isFalse);
    expect(workspace.budget.paused, isTrue);
    expect(workspace.budget.prepaidBalanceUsdMicros, isNull);
    expect(await File(note.sourcePath).readAsString(), contains('先保存原文'));
    await workspace.close();
    workspace = await NoteWorkspace.open(
      localDirectory: local,
      vaultDirectory: vault,
    );
    expect(workspace.notes.single.originalText, '先保存原文，连接后再整理。');
    expect(workspace.budget.message, contains('本机保存'));
    await workspace.close();
    await root.delete(recursive: true);
  });
}
