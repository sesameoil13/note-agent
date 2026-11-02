import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/note_workspace.dart';
import 'package:path/path.dart' as p;

import 'audio_queue_test.dart' show wave;
import 'support/ai_fixture.dart';

/// A capture is organized (整理, GLOSSARY) once. Later edits, made in the App
/// or in Obsidian, are never sent to AI; they only reach the other paired
/// devices through the vault, and those devices never send anything.
void main() {
  late AiFixture f;
  setUp(() async {
    f = AiFixture();
    await f.start();
  });
  tearDown(() => f.close());

  /// Stands in for Obsidian Sync mirroring device [from]'s vault files to
  /// device [to] (renamed or deleted files go too). Each copy carries the sending device's modification time,
  /// which in this fixture is the shared device clock (the App's own writes
  /// get the real file time, which the fake clock cannot order).
  Future<void> syncVault(int from, int to) async {
    final source = Directory('${f.root.path}/vault$from');
    final target = Directory('${f.root.path}/vault$to');
    await for (final entity in target.list(recursive: true)) {
      final relative = p.relative(entity.path, from: target.path);
      if (entity is File &&
          !relative.split(p.separator).any((s) => s.startsWith('.')) &&
          !await File('${source.path}/$relative').exists()) {
        await entity.delete();
      }
    }
    await for (final entity in source.list(recursive: true)) {
      if (entity is! File) continue;
      final relative = p.relative(entity.path, from: source.path);
      if (relative.split(p.separator).any((s) => s.startsWith('.'))) continue;
      final target = File('${f.root.path}/vault$to/$relative');
      await target.parent.create(recursive: true);
      await entity.copy(target.path);
      await target.setLastModified(f.now);
    }
  }

  Future<void> editInObsidian(
    WorkspaceNote note,
    String from,
    String to,
  ) async {
    final file = File(note.notePath);
    await file.writeAsString(
      (await file.readAsString()).replaceFirst(from, to),
    );
    f.now = f.now.add(const Duration(minutes: 2));
    await file.setLastModified(f.now);
  }

  test(
    'editing an organized note in Obsidian or in the App sends nothing to AI',
    () async {
      final w = f.workspaces.first;
      final captured = await w.captureText(title: '想法', text: '周末去公园散步。');
      await w.sendWaitingNow();
      expect(f.modelRequests, hasLength(1));
      var note = w.notes.single;
      expect(note.text, '整理后的普通想法。');

      await editInObsidian(note, '整理后的普通想法。', '在 Obsidian 里改过的想法。');
      expect(await w.readVaultEdits(), [captured.id]);
      await w.resolveNoteActions(
        captured.id,
        kind: NoteKind.ordinary,
        actions: const [],
        body: '在 App 里又改了一次。',
      );
      await w.sendWaitingNow();
      await f.reopen(0);
      await f.workspaces.first.sendWaitingNow();

      note = f.workspaces.first.notes.single;
      expect(note.text, '在 App 里又改了一次。');
      expect(
        f.workspaces.first.organizeStatus(note.id),
        OrganizeStatus.organized,
      );
      expect(f.modelRequests, hasLength(1));
    },
  );

  test(
    'correcting the transcript of an organized recording sends nothing to AI',
    () async {
      final w = f.workspaces.first;
      await w.importAudio(
        original: await File('${f.root.path}/a.wav').writeAsBytes(wave()),
        submissionId: 'corrected-audio',
      );
      await w.sendWaitingNow();
      final note = w.notes.single;
      expect(w.organizeStatus(note.id), OrganizeStatus.organized);

      final corrected = await w.correctTranscript(note.id, '明天下午三点整理会议记录。');
      await w.sendWaitingNow();
      await f.reopen(0);
      await f.workspaces.first.sendWaitingNow();

      expect(corrected.originalText, '明天下午三点整理会议记录。');
      expect(f.workspaces.first.notes.single.text, note.text);
      expect(f.audioRequests, hasLength(1));
      expect(f.modelRequests, hasLength(1));
    },
  );

  test('a second paired device shows the organized note and a later edit by sync, and never sends either', () async {
    final a = f.workspaces.first;
    final captured = await a.captureText(title: '想法', text: '周末去公园散步。');
    await a.sendWaitingNow();
    await syncVault(0, 1);

    final b = f.workspaces[1];
    expect(await b.readVaultEdits(), [captured.id]);
    var arrived = b.notes.single;
    expect(arrived.id, captured.id);
    expect(arrived.title, '记录想法');
    expect(arrived.text, '整理后的普通想法。');
    expect(arrived.originalText, '周末去公园散步。');
    expect(b.organizeStatus(captured.id), isNull);
    await b.sendWaitingNow();

    await editInObsidian(a.notes.single, '整理后的普通想法。', '在 A 上改过的想法。');
    expect(await a.readVaultEdits(), [captured.id]);
    await syncVault(0, 1);
    expect(await b.readVaultEdits(), [captured.id]);
    expect(b.notes.single.text, '在 A 上改过的想法。');
    await b.sendWaitingNow();
    await f.reopen(1);
    await f.workspaces[1].sendWaitingNow();
    await a.sendWaitingNow();

    expect(f.workspaces[1].notes.single.text, '在 A 上改过的想法。');
    expect(f.workspaces[1].notes, hasLength(1));
    expect(f.modelRequests, hasLength(1));
    expect(f.audioRequests, isEmpty);
  });

  test('an organized to-do note arrives with the same actions, so completions sync between devices', () async {
    f.modelResult = {
      'manifestVersion': 3,
      'kind': 'todo',
      'title': '买电池',
      'body': '明天买电池。',
      'actions': [
        {
          'text': '买电池',
          'reason': 'none',
          'timeExpression': '明天上午十点',
          'timeStatus': 'explicit',
        },
      ],
      'associations': [],
      'newTopics': [],
    };
    final a = f.workspaces.first;
    final captured = await a.captureText(title: '安排', text: '明天上午十点买电池。');
    await a.sendWaitingNow();
    final action = a.notes.single.actions.single;
    await a.completeAction(captured.id, action.id);
    expect(await a.syncTodos(), TaskStatusSync.synced);
    final b = f.workspaces[1];
    expect(await b.syncTodos(), TaskStatusSync.synced);
    expect(b.todoSync.awaitingNote.single.actionId, action.id);

    await syncVault(0, 1);
    await b.readVaultEdits();

    final arrived = b.notes.single;
    expect(arrived.kind, NoteKind.todo);
    expect(arrived.actions.single.id, action.id);
    expect(arrived.actions.single.text, '买电池');
    expect(b.todoSync.awaitingNote, isEmpty);
    expect(b.actionState(captured.id, action.id).completed, isTrue);
    await b.sendWaitingNow();
    expect(f.modelRequests, hasLength(1));
  });

  test('a capture that arrives before it is organized is replaced by the organized to-do when that arrives', () async {
    f.modelResult = {
      'manifestVersion': 3,
      'kind': 'todo',
      'title': '买电池',
      'body': '明天买电池。',
      'actions': [
        {
          'text': '买电池',
          'reason': 'none',
          'timeExpression': '明天上午十点',
          'timeStatus': 'explicit',
        },
      ],
      'associations': [],
      'newTopics': [],
    };
    final a = f.workspaces.first;
    final captured = await a.captureText(title: '安排', text: '明天上午十点买电池。');
    await syncVault(0, 1);
    final b = f.workspaces[1];
    await b.readVaultEdits();
    expect(b.notes.single.text, '明天上午十点买电池。');

    f.now = f.now.add(const Duration(minutes: 1));
    await a.sendWaitingNow();
    await syncVault(0, 1);
    await b.readVaultEdits();

    final arrived = b.notes.single;
    expect(arrived.id, captured.id);
    expect(arrived.title, '买电池');
    expect(arrived.kind, NoteKind.todo);
    expect(arrived.text, '明天买电池。');
    expect(arrived.actions.single.id, a.notes.single.actions.single.id);
    await b.sendWaitingNow();
    expect(f.modelRequests, hasLength(1));
  });

  test('a transcript corrected on the recording device reaches a paired device that already shows the note', () async {
    final a = f.workspaces.first;
    await a.importAudio(
      original: await File('${f.root.path}/a.wav').writeAsBytes(wave()),
      submissionId: 'synced-correction',
    );
    await a.sendWaitingNow();
    await syncVault(0, 1);
    final b = f.workspaces[1];
    await b.readVaultEdits();
    expect(b.notes.single.originalText, '明天下午两点整理会议记录。');

    await a.correctTranscript(a.notes.single.id, '明天下午三点整理会议记录。');
    await syncVault(0, 1);
    await b.readVaultEdits();

    expect(b.notes.single.originalText, '明天下午三点整理会议记录。');
    await f.reopen(1);
    expect(f.workspaces[1].notes.single.originalText, '明天下午三点整理会议记录。');
    expect(f.modelRequests, hasLength(1));
  });

  test('an action confirmed on the capturing device is confirmed on a paired device that already shows it', () async {
    f.modelResult = {
      'manifestVersion': 3,
      'kind': 'todo',
      'title': '联系物业',
      'body': '可能要联系物业。',
      'actions': [
        {
          'text': '联系物业',
          'reason': 'unclearAction',
          'timeExpression': '',
          'timeStatus': 'absent',
        },
      ],
      'associations': [],
      'newTopics': [],
    };
    final a = f.workspaces.first;
    final captured = await a.captureText(title: '物业', text: '可能要联系物业。');
    await a.sendWaitingNow();
    await syncVault(0, 1);
    final b = f.workspaces[1];
    await b.readVaultEdits();
    expect(b.notes.single.actions.single.actionConfirmed, isFalse);

    final pending = a.notes.single.actions.single;
    f.now = f.now.add(const Duration(minutes: 2));
    await a.resolveNoteActions(
      captured.id,
      kind: NoteKind.todo,
      actions: [
        WorkspaceAction(
          id: pending.id,
          text: pending.text,
          decision: ActionDecision.confirmed,
          reason: 'none',
        ),
      ],
    );
    await syncVault(0, 1);
    expect(await b.readVaultEdits(), [captured.id]);

    final action = b.notes.single.actions.single;
    expect(action.id, pending.id);
    expect(action.actionConfirmed, isTrue);
    expect(f.modelRequests, hasLength(1));
  });
}
