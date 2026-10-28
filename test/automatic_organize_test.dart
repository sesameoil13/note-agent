import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/note_workspace.dart';
import 'package:sqlite3/sqlite3.dart';

import 'support/ai_fixture.dart';

/// Automatic 整理 (GLOSSARY) of text and document captures: no estimate, no
/// confirmation and no budget request (ADR 0004).
void main() {
  late AiFixture f;
  setUp(() async {
    f = AiFixture();
    await f.start();
  });
  tearDown(() => f.close());

  test('a typed capture waits, then is organized by one qwen-plus request with no budget request', () async {
    final w = f.workspaces.first;
    final note = await w.captureText(title: '想法', text: '今天读完了一本关于习惯的书。');
    expect(w.organizeStatus(note.id), OrganizeStatus.waiting);

    await w.sendWaitingNow();

    expect(w.organizeStatus(note.id), OrganizeStatus.organized);
    final organized = w.notes.firstWhere((n) => n.id == note.id);
    expect(organized.title, '记录想法');
    expect(organized.text, '整理后的普通想法。');
    final request = f.modelRequests.single;
    expect(request['model'], 'qwen-plus');
    expect(request['enable_thinking'], isFalse);
    expect(f.workerPaths.where((p) => p.startsWith('/v1/budget')), isEmpty);
  });

  test('a capture shows 整理中 while its request is out', () async {
    final w = f.workspaces.first;
    final note = await w.captureText(title: '粘贴', text: '从网页粘贴的一段关于睡眠的笔记。');
    OrganizeStatus? during;
    f.beforeReply = () async => during = w.organizeStatus(note.id);

    await w.sendWaitingNow();

    expect(during, OrganizeStatus.organizing);
    expect(during!.label, '整理中');
    expect(w.organizeStatus(note.id)!.label, '已整理');
  });

  test('PDF and Word captures are organized from their extracted text, one request each', () async {
    final w = f.workspaces.first;
    final pdf = await w.importPdf(original: File('test/fixtures/table.pdf'));
    final word = await w.importDocument(
      original: File('test/fixtures/word/body-table.docx'),
    );
    expect(w.organizeStatus(pdf.id), OrganizeStatus.waiting);
    expect(w.organizeStatus(word.id), OrganizeStatus.waiting);

    await w.sendWaitingNow();

    expect(w.organizeStatus(pdf.id), OrganizeStatus.organized);
    expect(w.organizeStatus(word.id), OrganizeStatus.organized);
    final texts = [
      for (final r in f.modelRequests)
        (jsonDecode((r['messages'] as List).last['content'] as String)
            as Map)['text'],
    ];
    // Oldest first, each from its complete extracted source.
    expect(texts, [
      await File(pdf.sourcePath).readAsString(),
      await File(word.sourcePath).readAsString(),
    ]);
    expect(texts[1], contains('| 苹果 | 2 | A &#124; B |'));
    expect(f.workerPaths.where((p) => p.startsWith('/v1/budget')), isEmpty);
  });
  test('a capture edited before it is sent is organized from what was captured, and the edit stays', () async {
    final w = f.workspaces.first;
    final note = await w.captureText(title: '想法', text: '收集时的原文。');
    final file = File(note.notePath);
    await file.writeAsString(
      (await file.readAsString()).replaceFirst('收集时的原文。', '之后在 Obsidian 改过。'),
    );
    await file.setLastModified(f.now.add(const Duration(minutes: 1)));
    await w.readVaultEdits();
    expect(w.notes.single.text, '之后在 Obsidian 改过。');

    await w.sendWaitingNow();

    final input = jsonDecode(
      (f.modelRequests.single['messages'] as List).last['content'] as String,
    ) as Map;
    expect(input['text'], '收集时的原文。');
    expect(w.notes.single.text, contains('之后在 Obsidian 改过。'));
  });

  test(
    'a capture that cannot be read does not hold back later captures',
    () async {
      final w = f.workspaces.first;
      final lost = await w.captureText(title: '丢失', text: '文件之后被移走。');
      final later = await w.captureText(title: '之后', text: '之后收集的想法。');
      await File(lost.notePath).rename('${f.root.path}/moved-away.md');

      await w.sendWaitingNow();

      expect(w.organizeStatus(later.id), OrganizeStatus.organized);
      expect(f.modelRequests, hasLength(1));
    },
  );

  test('only the capturing device sends', () async {
    final note = await f.workspaces.first.captureText(
      title: '想法',
      text: '周末去公园散步。',
    );

    await f.workspaces[1].sendWaitingNow();
    expect(f.modelRequests, isEmpty);
    expect(f.workspaces[1].organizeStatus(note.id), isNull);

    await f.workspaces.first.sendWaitingNow();
    expect(f.modelRequests, hasLength(1));
  });

  test('on first open after upgrade, unfinished estimate jobs are dropped unsent and organized notes are untouched', () async {
    final w = f.workspaces.first;
    final organized = await w.captureText(title: '旧整理', text: '已经整理过的旧想法。');
    await w.sendWaitingNow();
    final organizedPath = w.notes
        .firstWhere((n) => n.id == organized.id)
        .notePath;
    final before = await File(organizedPath).readAsString();
    final pending = await w.captureText(title: '旧预估', text: '预估后尚未发送的旧想法。');
    await f.reopen(
      0,
      whileClosed: (local) {
        // Stand in for the old app's jobs: an organized one and one that was
        // estimated but never sent.
        final db = sqlite3.open('${local.path}/workspace.sqlite3');
        for (final row in db.select(
          'SELECT id,note_id,payload FROM text_jobs',
        )) {
          final payload = jsonDecode(row['payload'] as String) as Map
            ..remove('automatic');
          final old = row['note_id'] == pending.id;
          if (old) {
            payload['quote'] = {
              'id': 'q-old',
              'currency': 'CNY',
              'model': 'qwen-plus',
              'rateVersion': 'fixture',
              'promptNanoCny': 800,
              'completionNanoCny': 2000,
            };
            payload['original'] = '预估后尚未发送的旧想法。';
            payload['attempts'] = ['${row['id']}-0'];
          }
          db.execute('UPDATE text_jobs SET status=?,payload=? WHERE id=?', [
            old ? 'failed' : 'completed',
            jsonEncode(payload),
            row['id'],
          ]);
        }
        db.close();
      },
    );
    final reopened = f.workspaces.first;

    await reopened.sendWaitingNow();

    expect(f.modelRequests, hasLength(1));
    expect(reopened.organizeStatus(pending.id), isNull);
    expect(reopened.processingFailures, isEmpty);
    final kept = reopened.notes.firstWhere((n) => n.id == pending.id);
    expect(kept.text, '预估后尚未发送的旧想法。');
    expect(await File(kept.sourcePath).readAsString(), '预估后尚未发送的旧想法。');
    expect(reopened.organizeStatus(organized.id), OrganizeStatus.organized);
    expect(await File(organizedPath).readAsString(), before);
    expect(f.workerPaths.where((p) => p.startsWith('/v1/budget')), isEmpty);
  });
}
