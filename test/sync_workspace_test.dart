import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/connection.dart';
import 'package:note_agent/note_workspace.dart';

import 'support/budget_fixture.dart' show BudgetMemoryStore;

void main() {
  test(
    'local publication and restart never claim official cloud acknowledgement',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'note-agent-sync-',
      );
      final vault = await Directory('${temporary.path}/vault').create();
      final local = Directory('${temporary.path}/local');
      addTearDown(() => temporary.delete(recursive: true));
      var workspace = await NoteWorkspace.open(
        localDirectory: local,
        vaultDirectory: vault,
        createId: () => 'sync-unknown',
      );
      final saved = await workspace.captureText(
        title: '原文仍在本机',
        text: '等 Obsidian 运行后同步。',
      );
      expect(saved.status, NoteStatus.localSaved);
      expect(saved.syncStatus, NoteSyncStatus.unverified);
      expect(workspace.taskStatusSync, TaskStatusSync.notConnected);
      await workspace.close();
      workspace = await NoteWorkspace.open(
        localDirectory: local,
        vaultDirectory: vault,
      );
      addTearDown(workspace.close);
      expect(workspace.notes.single.syncStatus, NoteSyncStatus.unverified);
      expect(await File(saved.notePath).exists(), isTrue);
    },
  );
  test(
    'without a paired device to-do operations stay queued locally',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'note-agent-todo-unpaired-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final vault = await Directory('${temporary.path}/vault').create();
      final store = BudgetMemoryStore();
      final workspace = await NoteWorkspace.open(
        localDirectory: Directory('${temporary.path}/local'),
        vaultDirectory: vault,
        connection: WorkspaceConnection(secureStore: store),
      );
      addTearDown(workspace.close);
      final note = await workspace.captureText(title: '安排', text: '联系物业。');
      await workspace.resolveNoteActions(
        note.id,
        kind: NoteKind.todo,
        actions: const [
          WorkspaceAction(
            id: 'call',
            text: '联系物业',
            decision: ActionDecision.confirmed,
            reason: 'none',
          ),
        ],
      );
      await workspace.completeAction(note.id, 'call');
      expect(await workspace.syncTodos(), TaskStatusSync.notConnected);
      expect(workspace.todoSync.pendingOperations, 1);
      expect(workspace.todoSync.message, contains('保留在本机'));
      expect(workspace.actionState(note.id, 'call').completed, isTrue);
    },
  );
  test(
    'local vault estimate never stands in for available account storage',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'note-agent-capacity-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final vault = await Directory('${temporary.path}/vault').create();
      final large = await File('${vault.path}/existing.bin')
          .open(mode: FileMode.write);
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
    },
  );

  test(
    'oversized attachment keeps its complete original privately after restart',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'note-agent-oversize-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final vault = await Directory('${temporary.path}/vault').create();
      final local = Directory('${temporary.path}/local');
      final original = File('${temporary.path}/采访.m4a');
      final bytes = List<int>.generate(5000001, (index) => index % 251);
      await original.writeAsBytes(bytes);
      var sequence = 0;
      var workspace = await NoteWorkspace.open(
        localDirectory: local,
        vaultDirectory: vault,
        createId: () => 'oversize-${sequence++}',
      );
      final note = await workspace.captureText(title: '采访来源', text: '保留完整采访。');
      final attachment = await workspace.attachFile(
        noteId: note.id,
        original: original,
      );
      expect(attachment.status, AttachmentStatus.exceedsFileLimit);
      expect(attachment.originalByteLength, 5000001);
      expect(await File(attachment.originalPath).readAsBytes(), bytes);
      expect(attachment.originalPath.startsWith(local.path), isTrue);
      expect(await File(attachment.sourcePath).exists(), isFalse);
      expect(
        workspace.notes.single.syncStatus,
        NoteSyncStatus.attachmentBlocked,
      );
      await original.delete();
      await workspace.close();
      workspace = await NoteWorkspace.open(
        localDirectory: local,
        vaultDirectory: vault,
      );
      addTearDown(workspace.close);
      expect(
        workspace.attachments.single.status,
        AttachmentStatus.exceedsFileLimit,
      );
      expect(
        await File(workspace.attachments.single.originalPath).readAsBytes(),
        bytes,
      );
      final markdown = await File(note.notePath).readAsString();
      expect(
        RegExp(r'^## ', multiLine: true).allMatches(markdown),
        hasLength(3),
      );
      expect(markdown, contains('采访.m4a（仅本机保留，超过 Standard 单文件 5 MB）'));
    },
  );

  test('attachment at the conservative limit publishes a complete source without claiming sync', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'note-agent-filelimit-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final vault = await Directory('${temporary.path}/vault').create();
    final original = File('${temporary.path}/资料.pdf');
    final bytes = List<int>.filled(5000000, 37);
    await original.writeAsBytes(bytes);
    var sequence = 0;
    final workspace = await NoteWorkspace.open(
      localDirectory: Directory('${temporary.path}/local'),
      vaultDirectory: vault,
      createId: () => 'source-${sequence++}',
    );
    addTearDown(workspace.close);
    final note = await workspace.captureText(title: '资料来源', text: '原文先于附件。');
    final attachment = await workspace.attachFile(
      noteId: note.id,
      original: original,
    );
    expect(attachment.status, AttachmentStatus.localSaved);
    expect(await File(attachment.sourcePath).readAsBytes(), bytes);
    expect(await File(attachment.originalPath).readAsBytes(), bytes);
    expect(workspace.notes.single.syncStatus, NoteSyncStatus.unverified);
    final markdown = await File(note.notePath).readAsString();
    expect(markdown.indexOf('[原始文字]'), lessThan(markdown.indexOf('[资料.pdf]')));
    expect(markdown, contains('[资料.pdf](attachments/note-agent/source-1/'));
    expect(RegExp(r'^## ', multiLine: true).allMatches(markdown), hasLength(3));
  });

  test('an explicit smaller copy publishes separately while the oversized original stays intact', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'note-agent-derivative-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final vault = await Directory('${temporary.path}/vault').create();
    final local = Directory('${temporary.path}/local');
    final original = await File('${temporary.path}/完整采访.m4a')
        .writeAsBytes(List<int>.filled(5000001, 71));
    final derivative = await File('${temporary.path}/采访精简.m4a')
        .writeAsBytes([1, 5, 9, 13]);
    var sequence = 0;
    var workspace = await NoteWorkspace.open(
      localDirectory: local,
      vaultDirectory: vault,
      createId: () => 'copy-${sequence++}',
    );
    final note = await workspace.captureText(title: '采访', text: '原音频继续保留。');
    final blocked = await workspace.attachFile(
      noteId: note.id,
      original: original,
    );
    final selected = await workspace.chooseAttachmentCopy(
      attachmentId: blocked.id,
      copy: derivative,
    );
    expect(selected.status, AttachmentStatus.localSaved);
    expect(selected.copyName, '采访精简.m4a');
    expect(selected.hasLocalOnlyOriginal, isTrue);
    expect(await File(selected.sourcePath).readAsBytes(), [1, 5, 9, 13]);
    expect(await File(selected.originalPath).length(), 5000001);
    expect(
      await File(selected.originalPath).readAsBytes(),
      List<int>.filled(5000001, 71),
    );
    await workspace.close();
    workspace = await NoteWorkspace.open(
      localDirectory: local,
      vaultDirectory: vault,
    );
    addTearDown(workspace.close);
    expect(workspace.attachments.single.copyName, '采访精简.m4a');
    final markdown = await File(note.notePath).readAsString();
    expect(markdown, contains('[采访精简.m4a（精简副本）]'));
    expect(markdown, contains('完整采访.m4a（原件仅本机保留）'));
    expect(workspace.notes.single.syncStatus, NoteSyncStatus.attachmentBlocked);
  });

  test('choosing local retention persists and never publishes an oversized original', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'note-agent-retain-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final vault = await Directory('${temporary.path}/vault').create();
    final local = Directory('${temporary.path}/local');
    final original = await File('${temporary.path}/完整资料.pdf')
        .writeAsBytes(List<int>.filled(5000001, 19));
    var sequence = 0;
    var workspace = await NoteWorkspace.open(
      localDirectory: local,
      vaultDirectory: vault,
      createId: () => 'retain-${sequence++}',
    );
    final note = await workspace.captureText(title: '资料', text: '无需为了同步破坏原件。');
    final blocked = await workspace.attachFile(
      noteId: note.id,
      original: original,
    );
    final retained = await workspace.retainAttachmentLocally(blocked.id);
    expect(retained.status, AttachmentStatus.retainedLocal);
    expect(await File(retained.sourcePath).exists(), isFalse);
    await workspace.close();
    workspace = await NoteWorkspace.open(
      localDirectory: local,
      vaultDirectory: vault,
    );
    addTearDown(workspace.close);
    expect(workspace.attachments.single.status, AttachmentStatus.retainedLocal);
    expect(await File(retained.originalPath).length(), 5000001);
    expect(workspace.notes.single.syncStatus, NoteSyncStatus.attachmentBlocked);
  });

  test('interrupted source-link publication recovers once without replacing external content', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'note-agent-source-recovery-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final vault = await Directory('${temporary.path}/vault').create();
    final local = Directory('${temporary.path}/local');
    final original = await File('${temporary.path}/资料.pdf')
        .writeAsBytes([10, 20, 30]);
    var sequence = 0;
    var workspace = await NoteWorkspace.open(
      localDirectory: local,
      vaultStorage: _InterruptedSourceStorage(
        Directory(await vault.resolveSymbolicLinks()),
      ),
      createId: () => 'recover-${sequence++}',
    );
    final note = await workspace.captureText(title: '恢复来源', text: '正文保持完整。');
    await expectLater(
      workspace.attachFile(noteId: note.id, original: original),
      throwsStateError,
    );
    await workspace.close();
    workspace = await NoteWorkspace.open(
      localDirectory: local,
      vaultDirectory: vault,
    );
    addTearDown(workspace.close);
    expect(workspace.attachments.single.status, AttachmentStatus.localSaved);
    expect(await File(workspace.attachments.single.sourcePath).readAsBytes(), [
      10,
      20,
      30,
    ]);
    final markdown = await File(note.notePath).readAsString();
    expect('[资料.pdf]'.allMatches(markdown), hasLength(1));
    expect(markdown, contains('正文保持完整。'));
  });
  test('closing waits for accepted attachment publication and preserves it on restart', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'note-agent-attachment-close-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final vault = await Directory('${temporary.path}/vault').create();
    final local = Directory('${temporary.path}/local');
    final storage = _GatedAttachmentStorage(
      Directory(await vault.resolveSymbolicLinks()),
    );
    var sequence = 0;
    var workspace = await NoteWorkspace.open(
      localDirectory: local,
      vaultStorage: storage,
      createId: () => 'close-${sequence++}',
    );
    final note = await workspace.captureText(
      title: '退出时保留来源',
      text: '已接收的来源必须完成。',
    );
    final original = await File('${temporary.path}/资料.pdf')
        .writeAsBytes([5, 10, 15]);
    final attaching = workspace.attachFile(noteId: note.id, original: original);
    await storage.started.future;
    var closed = false;
    final closing = workspace.close().then((_) => closed = true);
    await Future<void>.delayed(Duration.zero);
    expect(closed, isFalse);
    storage.release.complete();
    await attaching;
    await closing;
    workspace = await NoteWorkspace.open(
      localDirectory: local,
      vaultDirectory: vault,
    );
    addTearDown(workspace.close);
    expect(workspace.attachments.single.status, AttachmentStatus.localSaved);
    expect(await File(workspace.attachments.single.sourcePath).readAsBytes(), [
      5,
      10,
      15,
    ]);
    expect(await File(note.notePath).readAsString(), contains('[资料.pdf]'));
  });
  test('a published vault copy with a failed source link is never called local only', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'note-agent-source-link-error-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final vault = await Directory('${temporary.path}/vault').create();
    final storage = _RefusingSourceLinkStorage(
      Directory(await vault.resolveSymbolicLinks()),
    );
    var sequence = 0;
    final workspace = await NoteWorkspace.open(
      localDirectory: Directory('${temporary.path}/local'),
      vaultStorage: storage,
      createId: () => 'link-${sequence++}',
    );
    addTearDown(workspace.close);
    final note = await workspace.captureText(
      title: '来源链接待修复',
      text: '附件副本的写入与链接写入是不同结果。',
    );
    final original = await File('${temporary.path}/资料.pdf')
        .writeAsBytes([4, 8, 12]);
    final attachment = await workspace.attachFile(
      noteId: note.id,
      original: original,
    );
    expect(attachment.status, AttachmentStatus.exportFailed);
    expect(await File(attachment.sourcePath).readAsBytes(), [4, 8, 12]);
    expect(attachment.hasLocalOnlyOriginal, isFalse);
    expect(attachment.vaultCopyPublished, isTrue);
    await expectLater(
      workspace.retainAttachmentLocally(attachment.id),
      throwsArgumentError,
    );
    expect(workspace.notes.single.syncStatus, NoteSyncStatus.unverified);
  });
  test('reopening completes a durable failed source link without leaving a false failure', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'note-agent-source-link-retry-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final vault = await Directory('${temporary.path}/vault').create();
    final local = Directory('${temporary.path}/local');
    final storage = _RefusingSourceLinkStorage(
      Directory(await vault.resolveSymbolicLinks()),
    );
    var sequence = 0;
    var workspace = await NoteWorkspace.open(
      localDirectory: local,
      vaultStorage: storage,
      createId: () => 'retry-link-${sequence++}',
    );
    final note = await workspace.captureText(title: '修复来源', text: '重启后继续完成来源。');
    final original = await File('${temporary.path}/资料.pdf')
        .writeAsBytes([7, 14, 21]);
    final failed = await workspace.attachFile(
      noteId: note.id,
      original: original,
    );
    expect(failed.status, AttachmentStatus.exportFailed);
    await workspace.close();
    workspace = await NoteWorkspace.open(
      localDirectory: local,
      vaultDirectory: vault,
    );
    addTearDown(workspace.close);
    expect(workspace.attachments.single.status, AttachmentStatus.localSaved);
    expect(workspace.attachments.single.error, isNull);
    expect(
      '[资料.pdf]'.allMatches(await File(note.notePath).readAsString()),
      hasLength(1),
    );
  });
  test('a failed binary acknowledgement cannot claim the original stayed outside the vault', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'note-agent-source-uncertain-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final vault = await Directory('${temporary.path}/vault').create();
    final storage = _AfterCommitFailureStorage(
      Directory(await vault.resolveSymbolicLinks()),
    );
    var sequence = 0;
    final workspace = await NoteWorkspace.open(
      localDirectory: Directory('${temporary.path}/local'),
      vaultStorage: storage,
      createId: () => 'uncertain-${sequence++}',
    );
    addTearDown(workspace.close);
    final note = await workspace.captureText(
      title: '核对附件',
      text: '失败可能发生在文件写入之后。',
    );
    final original = await File('${temporary.path}/资料.pdf')
        .writeAsBytes([6, 12, 18]);
    final attachment = await workspace.attachFile(
      noteId: note.id,
      original: original,
    );
    expect(attachment.status, AttachmentStatus.exportFailed);
    expect(await File(attachment.sourcePath).readAsBytes(), [6, 12, 18]);
    expect(attachment.hasLocalOnlyOriginal, isFalse);
    await expectLater(
      workspace.retainAttachmentLocally(attachment.id),
      throwsArgumentError,
    );
    expect(workspace.notes.single.syncStatus, NoteSyncStatus.unverified);
  });
}

class _InterruptedSourceStorage extends DirectoryVaultStorage {
  _InterruptedSourceStorage(super.directory);

  @override
  Future<void> replaceText(
    String relativePath,
    String expectedText,
    String text,
    String operationId,
  ) async {
    await super.replaceText(relativePath, expectedText, text, operationId);
    throw StateError(
      'Simulated interruption after complete source-link publication',
    );
  }
}

class _GatedAttachmentStorage extends DirectoryVaultStorage {
  _GatedAttachmentStorage(super.directory);
  final started = Completer<void>();
  final release = Completer<void>();

  @override
  Future<void> publishFile(
    String relativePath,
    File original,
    String operationId,
  ) async {
    started.complete();
    await release.future;
    await super.publishFile(relativePath, original, operationId);
  }
}

class _RefusingSourceLinkStorage extends DirectoryVaultStorage {
  _RefusingSourceLinkStorage(super.directory);

  @override
  Future<void> replaceText(
    String relativePath,
    String expectedText,
    String text,
    String operationId,
  ) async {
    throw const FileSystemException('Simulated source-link permission failure');
  }
}

class _AfterCommitFailureStorage extends DirectoryVaultStorage {
  _AfterCommitFailureStorage(super.directory);

  @override
  Future<void> publishFile(
    String relativePath,
    File original,
    String operationId,
  ) async {
    await super.publishFile(relativePath, original, operationId);
    throw const FileSystemException(
      'Simulated readback failure after binary publication',
    );
  }
}
