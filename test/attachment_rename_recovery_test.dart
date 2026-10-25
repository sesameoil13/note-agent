import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/note_workspace.dart';

void main() {
  test('retrying a failed attachment source link remains possible after app title rename', () async {
    final temporary = await Directory.systemTemp.createTemp(
      't05-review-rename-',
    );
    final vault = await Directory('${temporary.path}/vault').create();
    final storage = _RefusingSourceLinkStorage(
      Directory(await vault.resolveSymbolicLinks()),
    );
    var sequence = 0;
    var now = DateTime(2026, 10, 16, 10);
    var workspace = await NoteWorkspace.open(
      localDirectory: Directory('${temporary.path}/local'),
      vaultStorage: storage,
      createId: () => 'review-${sequence++}',
      clock: () => now,
    );
    addTearDown(() async {
      await workspace.close();
      await temporary.delete(recursive: true);
    });
    final note = await workspace.captureText(title: '原标题', text: '保存原文与来源。');
    final original = await File('${temporary.path}/资料.pdf')
        .writeAsBytes([3, 6, 9]);
    final failed = await workspace.attachFile(
      noteId: note.id,
      original: original,
    );
    expect(failed.status, AttachmentStatus.exportFailed);
    expect(await File(failed.sourcePath).readAsBytes(), [3, 6, 9]);
    final beforeRename = await File(note.notePath).readAsString();
    await File(note.notePath)
        .writeAsString(beforeRename.replaceFirst('保存原文与来源。', '外部新正文必须保留。'));
    storage.refuse = false;
    now = now.add(const Duration(minutes: 1));
    final renamed = await workspace.renameNote(note.id, title: '新标题');
    expect(renamed.status, NoteStatus.localSaved);
    await workspace.close();
    workspace = await NoteWorkspace.open(
      localDirectory: Directory('${temporary.path}/local'),
      vaultDirectory: vault,
      clock: () => now,
    );
    final retried = await workspace.retryAttachmentExport(failed.id);
    expect(retried.status, AttachmentStatus.localSaved, reason: retried.error);
    await workspace.retryAttachmentExport(failed.id);
    final saved = await File(renamed.notePath).readAsString();
    expect('[资料.pdf]'.allMatches(saved), hasLength(1));
    expect(saved, contains('外部新正文必须保留。'));
    // T24: the later external body is adopted on open, and the note's own
    // modification line follows that adopted version.
    expect(workspace.notes.single.text, '外部新正文必须保留。');
    expect(
      saved,
      contains('修改：${formatNoteTime(workspace.notes.single.modifiedAt)}'),
    );
    expect(workspace.notes.single.id, note.id);
    expect(workspace.attachments.single.originalPath, failed.originalPath);
    expect(await File(failed.originalPath).readAsBytes(), [3, 6, 9]);
  });
  test('external edits after the owned rename are preserved and the pending source stays unconfirmed', () async {
    final temporary = await Directory.systemTemp.createTemp(
      't05-rename-external-',
    );
    final vault = await Directory('${temporary.path}/vault').create();
    final storage = _RefusingSourceLinkStorage(
      Directory(await vault.resolveSymbolicLinks()),
    );
    var sequence = 0;
    var now = DateTime(2026, 10, 16, 10);
    final workspace = await NoteWorkspace.open(
      localDirectory: Directory('${temporary.path}/local'),
      vaultStorage: storage,
      createId: () => 'external-${sequence++}',
      clock: () => now,
    );
    addTearDown(() async {
      await workspace.close();
      await temporary.delete(recursive: true);
    });
    final note = await workspace.captureText(title: '原标题', text: '保存原文与来源。');
    final original = await File('${temporary.path}/资料.pdf')
        .writeAsBytes([2, 4, 6]);
    final failed = await workspace.attachFile(
      noteId: note.id,
      original: original,
    );
    storage.refuse = false;
    now = now.add(const Duration(minutes: 1));
    final renamed = await workspace.renameNote(note.id, title: '新标题');
    final renamedText = await File(renamed.notePath).readAsString();
    final external = renamedText.replaceFirst('保存原文与来源。', '改名之后的外部新正文。');
    await File(renamed.notePath).writeAsString(external);
    final retried = await workspace.retryAttachmentExport(failed.id);
    expect(retried.status, AttachmentStatus.exportFailed);
    expect(retried.error, isNotEmpty);
    expect(await File(renamed.notePath).readAsString(), external);
    expect(await File(failed.originalPath).readAsBytes(), [2, 4, 6]);
    expect(await File(failed.sourcePath).readAsBytes(), [2, 4, 6]);
  });
  test(
    'recovering one renamed source does not strand another pending attachment',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        't05-rename-siblings-',
      );
      final vault = await Directory('${temporary.path}/vault').create();
      final local = Directory('${temporary.path}/local');
      final storage = _RefusingSourceLinkStorage(
        Directory(await vault.resolveSymbolicLinks()),
      );
      var sequence = 0;
      var now = DateTime(2026, 10, 16, 10);
      var workspace = await NoteWorkspace.open(
        localDirectory: local,
        vaultStorage: storage,
        createId: () => 'siblings-${sequence++}',
        clock: () => now,
      );
      addTearDown(() async {
        await workspace.close();
        await temporary.delete(recursive: true);
      });
      final note = await workspace.captureText(title: '原标题', text: '两个来源均应保留。');
      for (final name in ['第一份.pdf', '第二份.pdf']) {
        final original = await File('${temporary.path}/$name')
            .writeAsBytes([1, 3, 5]);
        expect(
          (await workspace.attachFile(
            noteId: note.id,
            original: original,
          )).status,
          AttachmentStatus.exportFailed,
        );
      }
      storage.refuse = false;
      now = now.add(const Duration(minutes: 1));
      final renamed = await workspace.renameNote(note.id, title: '新标题');
      await workspace.close();
      workspace = await NoteWorkspace.open(
        localDirectory: local,
        vaultDirectory: vault,
      );
      final markdown = await File(renamed.notePath).readAsString();
      expect(
        workspace.attachments.map((item) => item.status),
        everyElement(AttachmentStatus.localSaved),
      );
      expect('[第一份.pdf]'.allMatches(markdown), hasLength(1));
      expect('[第二份.pdf]'.allMatches(markdown), hasLength(1));
      for (final attachment in workspace.attachments) {
        expect(await File(attachment.originalPath).readAsBytes(), [1, 3, 5]);
      }
    },
  );
}

class _RefusingSourceLinkStorage extends DirectoryVaultStorage {
  _RefusingSourceLinkStorage(super.directory);
  bool refuse = true;
  @override
  Future<void> replaceText(
    String path,
    String expected,
    String text,
    String operation,
  ) async {
    if (refuse) {
      throw const FileSystemException(
        'Simulated source-link permission failure',
      );
    }
    await super.replaceText(path, expected, text, operation);
  }
}
