import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/note_workspace.dart';

void main() {
  test('pending source retry survives an app rename updating an inbound collected note', () async {
    final temp = await Directory.systemTemp.createTemp('t05-inbound-source-');
    final vault = await Directory('${temp.path}/vault').create();
    final storage = _SourceFailure(
      Directory(await vault.resolveSymbolicLinks()),
    );
    var id = 0;
    final workspace = await NoteWorkspace.open(
      localDirectory: Directory('${temp.path}/local'),
      vaultStorage: storage,
      createId: () => 'probe-${id++}',
    );
    addTearDown(() async {
      await workspace.close();
      await temp.delete(recursive: true);
    });
    final target = await workspace.captureText(title: '目标', text: '目标内容');
    final referring = await workspace.captureText(
      title: '索引',
      text: '请阅读 [[目标]]。',
    );
    final source = await File('${temp.path}/资料.pdf').writeAsBytes([2, 4, 6]);
    final attachment = await workspace.attachFile(
      noteId: referring.id,
      original: source,
    );
    expect(attachment.status, AttachmentStatus.exportFailed);
    storage.refuse = false;
    await workspace.renameNote(target.id, title: '新目标');
    expect(await File(referring.notePath).readAsString(), contains('[[新目标]]'));
    final retried = await workspace.retryAttachmentExport(attachment.id);
    expect(retried.status, AttachmentStatus.localSaved, reason: retried.error);
    expect(await File(referring.notePath).readAsString(), contains('[资料.pdf]'));
    expect(await File(referring.notePath).readAsString(), contains('[[新目标]]'));
  });
  test('restart acknowledges an interrupted inbound write before recovering its pending source once', () async {
    final temp = await Directory.systemTemp.createTemp(
      't05-inbound-interrupted-',
    );
    final vault = await Directory('${temp.path}/vault').create();
    final local = Directory('${temp.path}/local');
    final storage = _SourceFailure(
      Directory(await vault.resolveSymbolicLinks()),
    );
    var id = 0;
    var workspace = await NoteWorkspace.open(
      localDirectory: local,
      vaultStorage: storage,
      createId: () => 'interrupted-${id++}',
    );
    addTearDown(() async {
      await workspace.close();
      await temp.delete(recursive: true);
    });
    final target = await workspace.captureText(title: '目标', text: '目标内容');
    final referring = await workspace.captureText(
      title: '索引',
      text: '请阅读 [[目标]]。保留这句正文。',
    );
    final source = await File('${temp.path}/资料.pdf').writeAsBytes([7, 14, 21]);
    final attachment = await workspace.attachFile(
      noteId: referring.id,
      original: source,
    );
    storage.refuse = false;
    storage.interruptInboundOnce = true;
    await expectLater(
      workspace.renameNote(target.id, title: '新目标'),
      throwsStateError,
    );
    expect(await File(referring.notePath).readAsString(), contains('[[新目标]]'));
    await workspace.close();
    workspace = await NoteWorkspace.open(
      localDirectory: local,
      vaultDirectory: vault,
    );
    expect(
      workspace.notes.firstWhere((note) => note.id == target.id).title,
      '新目标',
    );
    expect(workspace.attachments.single.status, AttachmentStatus.localSaved);
    await workspace.retryAttachmentExport(attachment.id);
    await workspace.retryAttachmentExport(attachment.id);
    final saved = await File(referring.notePath).readAsString();
    expect('[资料.pdf]'.allMatches(saved), hasLength(1));
    expect(saved, contains('[[新目标]]。保留这句正文。'));
    expect(await File(attachment.originalPath).readAsBytes(), [7, 14, 21]);
    expect(await File(attachment.sourcePath).readAsBytes(), [7, 14, 21]);
  });
}

class _SourceFailure extends DirectoryVaultStorage {
  _SourceFailure(super.directory);
  bool refuse = true;
  bool interruptInboundOnce = false;
  @override
  Future<void> replaceText(
    String path,
    String before,
    String after,
    String operation,
  ) async {
    if (refuse) {
      throw const FileSystemException('Source link unavailable');
    }
    await super.replaceText(path, before, after, operation);
    if (interruptInboundOnce &&
        operation.startsWith('rename-') &&
        path == '索引.md') {
      interruptInboundOnce = false;
      throw StateError(
        'Simulated interruption after inbound file commit before source-plan acknowledgement',
      );
    }
  }
}
