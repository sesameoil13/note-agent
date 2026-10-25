import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/note_workspace.dart';

void main() {
  late Directory temporary;
  late Directory local;
  late Directory vault;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('note-agent-t01-');
    local = Directory('${temporary.path}/local');
    vault = await Directory('${temporary.path}/test-vault').create();
  });

  tearDown(() async {
    await temporary.delete(recursive: true);
  });

  test(
    'collected ordinary note and original text survive workspace restart',
    () async {
      final workspace = await NoteWorkspace.open(
        localDirectory: local,
        vaultDirectory: vault,
        clock: () => DateTime(2026, 10, 15, 9, 30),
        createId: () => 'capture-001',
      );
      final collected = await workspace.captureText(
        title: '产品观察',
        text: '清晰的正文比装饰更重要。\n保留这一行原文。\n',
      );
      final notePath = collected.notePath;
      final sourcePath = collected.sourcePath;
      await workspace.close();

      final reopened = await NoteWorkspace.open(
        localDirectory: local,
        vaultDirectory: vault,
      );
      addTearDown(reopened.close);
      final note = reopened.notes.single;
      expect(note.id, 'capture-001');
      expect(note.title, '产品观察');
      expect(note.text, '清晰的正文比装饰更重要。\n保留这一行原文。\n');
      expect(note.status, NoteStatus.localSaved);
      expect(await File(sourcePath).readAsString(), note.text);
      expect(await File(notePath).readAsString(), '''## 正文

清晰的正文比装饰更重要。
保留这一行原文。

## 关联

暂无关联

## 来源

[原始文字](attachments/note-agent/capture-001.txt)

记录：2026-10-15 09:30:00 · 修改：2026-10-15 09:30:00
''');
    },
  );

  test(
    'failed vault write retains original text and can retry after restart',
    () async {
      await File('${vault.path}/attachments')
          .writeAsString('blocked directory');
      final workspace = await NoteWorkspace.open(
        localDirectory: local,
        vaultDirectory: vault,
        createId: () => 'capture-retry',
      );
      final collected = await workspace.captureText(
        title: '仍然保留的记录',
        text: '即使笔记库暂时不可写，原文也要留下。',
      );
      expect(collected.status, NoteStatus.exportFailed);
      expect(collected.error, isNotEmpty);
      await workspace.close();

      final reopened = await NoteWorkspace.open(
        localDirectory: local,
        vaultDirectory: vault,
      );
      addTearDown(reopened.close);
      expect(reopened.notes.single.text, '即使笔记库暂时不可写，原文也要留下。');
      expect(reopened.notes.single.status, NoteStatus.exportFailed);
      await File('${vault.path}/attachments').delete();
      final retried = await reopened.retryNoteExport(collected.id);
      expect(retried.status, NoteStatus.localSaved);
      expect(reopened.notes, hasLength(1));
      expect(
        await File(retried.sourcePath).readAsString(),
        '即使笔记库暂时不可写，原文也要留下。',
      );
      expect(await File(retried.notePath).exists(), isTrue);
    },
  );

  test('interrupted publication recovers durable original without exposing a partial note', () async {
    final interrupted = await NoteWorkspace.open(
      localDirectory: local,
      vaultDirectory: vault,
      createId: () => 'interrupted-capture',
      filePublisher: _InterruptedFilePublisher(),
    );
    await expectLater(
      interrupted.captureText(title: '意外退出后恢复', text: '完整的原文必须在重启后恢复。'),
      throwsStateError,
    );
    expect(interrupted.notes.single.status, NoteStatus.exportPending);
    expect(await File(interrupted.notes.single.notePath).exists(), isFalse);
    await interrupted.close();

    final reopened = await NoteWorkspace.open(
      localDirectory: local,
      vaultDirectory: vault,
    );
    addTearDown(reopened.close);
    final recovered = reopened.notes.single;
    expect(recovered.status, NoteStatus.localSaved);
    expect(await File(recovered.sourcePath).readAsString(), '完整的原文必须在重启后恢复。');
    expect(
      await File(recovered.notePath).readAsString(),
      contains('完整的原文必须在重启后恢复。'),
    );
  });

  test('publication never replaces an unrelated existing note', () async {
    final existing = File('${vault.path}/现有笔记.md');
    await existing.writeAsString('用户已有的内容');
    final workspace = await NoteWorkspace.open(
      localDirectory: local,
      vaultDirectory: vault,
    );
    addTearDown(workspace.close);
    final collected = await workspace.captureText(
      title: '现有笔记',
      text: '新的原文也应保留。',
    );
    expect(collected.status, NoteStatus.localSaved);
    expect(collected.title, '现有笔记 (2)');
    expect(collected.titleCollision, isTrue);
    expect(collected.text, '新的原文也应保留。');
    await workspace.retryNoteExport(collected.id);
    expect(await existing.readAsString(), '用户已有的内容');
  });
}

/// Fault injection at the system-file boundary, using an actual partial staging file.
class _InterruptedFilePublisher implements NoteFilePublisher {
  @override
  Future<void> publish({
    required File destination,
    required File staging,
    required String text,
  }) async {
    if (destination.path.endsWith('.txt')) {
      return AtomicNoteFilePublisher().publish(
        destination: destination,
        staging: staging,
        text: text,
      );
    }
    await staging.parent.create(recursive: true);
    await staging.writeAsString('partial', flush: true);
    throw StateError(
      'Simulated process interruption before atomic publication',
    );
  }
}
