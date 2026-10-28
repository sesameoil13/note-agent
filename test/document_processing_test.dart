import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/note_workspace.dart';

import 'support/budget_fixture.dart';
import 'support/organize_now.dart';

void main() {
  test('a retained Word table goes through the semantic pipeline without replacing its complete source', () async {
    final f = BudgetFixture();
    await f.start();
    addTearDown(f.close);
    final w = f.workspaces.first;
    final topic = await w.captureText(title: '产品研究', text: '收集产品使用情况。');
    f.keepAsIs(topic);
    final note = await w.importDocument(
      original: File('test/fixtures/word/body-table.docx'),
    );
    final extraction = jsonEncode(note.document!.result!.toJson());
    final raw = await File(note.sourcePath).readAsString();
    final attachment = note.attachments.single;
    final original = await File(attachment.originalPath).readAsBytes();
    final before = await File(note.notePath).readAsString();
    await File(note.notePath).writeAsString(
      before
          .replaceFirst('暂无关联', '- [[手工主题]]')
          .replaceFirst('\n记录：', '\n[手工来源](manual.txt)\n\n记录：'),
    );
    f.modelResult = {
      'manifestVersion': 3,
      'kind': 'ordinary',
      'title': '产品记录',
      'body': '记录产品及相关资料。',
      'actions': [],
      'associations': [
        {'noteId': topic.id, 'reason': '文档中的产品资料与该主题相关。'},
      ],
      'newTopics': [],
    };
    final job = await w.organizeNow(note.id);
    expect(job.status, TextProcessingStatus.completed);
    final saved = w.notes.firstWhere((n) => n.id == note.id);
    expect(saved.title, '产品记录');
    expect(saved.kind, NoteKind.ordinary);
    expect(saved.text, '记录产品及相关资料。');
    expect(saved.originalText, raw);
    expect(saved.associations.single.targetNoteId, topic.id);
    expect(jsonEncode(saved.document!.result!.toJson()), extraction);
    expect(
      saved.document!.result!.tables.single.rows[2][2].location.part,
      'word/document.xml#block=1/row=2/cell=2',
    );
    expect(await File(saved.sourcePath).readAsString(), raw);
    expect(
      await File(saved.attachments.single.originalPath).readAsBytes(),
      original,
    );
    expect(
      await File(saved.attachments.single.sourcePath).readAsBytes(),
      original,
    );
    final markdown = await File(saved.notePath).readAsString();
    expect(
      RegExp(r'^## .+$', multiLine: true).allMatches(markdown).map((m) => m[0]),
      ['## 正文', '## 关联', '## 来源'],
    );
    expect(markdown, contains('body-table.docx'));
    expect(markdown, contains('[手工来源](manual.txt)'));
    expect(markdown, contains('[[手工主题]]'));
    expect(markdown, contains('提取结果'));
    final input = jsonDecode(
      f.requestsFor(note.id).single['messages'].last['content'] as String,
    ) as Map;
    expect(input['text'], raw);
    expect(input['text'], contains('| 苹果 | 2 | A &#124; B |'));
    await f.reopen(0);
    expect(f.workspaces.first.notes.length, 2);
    expect(
      f.workspaces.first.notes.firstWhere((n) => n.id == note.id).originalText,
      raw,
    );
    expect(f.requestsFor(note.id), hasLength(1));
  });
  test('mixed Word images stay disclosed while extracted text can form a todo and be corrected locally', () async {
    final f = BudgetFixture();
    await f.start();
    addTearDown(f.close);
    final w = f.workspaces.first;
    final note = await w.importDocument(
      original: File('test/fixtures/word/mixed.docx'),
    );
    final raw = await File(note.sourcePath).readAsString();
    expect(w.textProcessingReadiness(note.id).canPrepare, isTrue);
    expect(w.textProcessingReadiness(note.id).message, contains('扫描页、图片'));
    f.modelResult = {
      'manifestVersion': 3,
      'kind': 'todo',
      'title': '查看配图',
      'body': '查看配图前后的文字。',
      'actions': [
        {
          'text': '查看配图前后的文字',
          'reason': 'none',
          'timeExpression': '',
          'timeStatus': 'absent',
        },
      ],
      'associations': [],
      'newTopics': [],
    };
    expect(
      (await w.organizeNow(note.id)).status,
      TextProcessingStatus.completed,
    );
    var saved = w.notes.single;
    expect(saved.kind, NoteKind.todo);
    expect(saved.document!.result!.completion, DocumentCompletion.partial);
    expect(saved.document!.result!.unprocessed, isNotEmpty);
    final md = await File(saved.notePath).readAsString();
    expect(
      RegExp(r'^## .+$', multiLine: true).allMatches(md).map((m) => m[0]),
      ['## 待办', '## 摘要', '## 关联', '## 来源'],
    );
    expect(md, contains('mixed.docx'));
    expect(md, contains('未处理'));
    await w.resolveNoteActions(
      note.id,
      kind: NoteKind.ordinary,
      actions: [],
      body: '只保留已提取的文字。',
    );
    saved = w.notes.single;
    expect(saved.kind, NoteKind.ordinary);
    expect(saved.originalText, raw);
    expect(
      saved.document!.result!.problems.map((p) => p.code),
      containsAll(['imageRegion', 'unsupportedStory']),
    );
    expect(await File(saved.notePath).readAsString(), contains('mixed.docx'));
    expect(await File(saved.sourcePath).readAsString(), raw);
    expect(f.modelRequests.length, 1);
    await f.reopen(0);
    expect(f.workspaces.first.notes.single.originalText, raw);
    expect(f.workspaces.first.notes.single.kind, NoteKind.ordinary);
  });
  test(
    'image-only, scanned and failed documents never send placeholder text',
    () async {
      final f = BudgetFixture();
      await f.start();
      addTearDown(f.close);
      final w = f.workspaces.first;
      for (final path in [
        'word/images-only.docx',
        'scan.pdf',
        'word/broken.docx',
      ]) {
        final note = await w.importDocument(
          original: File('test/fixtures/$path'),
        );
        expect(
          w.textProcessingReadiness(note.id).canPrepare,
          isFalse,
          reason: path,
        );
        expect(
          await File(note.attachments.single.originalPath).exists(),
          isTrue,
        );
      }
      await expectLater(
        w.importDocument(original: File('${f.root.path}/missing.docx')),
        throwsA(isA<FileSystemException>()),
      );
      final unready = w.notes.firstWhere(
        (n) => n.document!.status == DocumentImportStatus.originalFailed,
      );
      expect(w.textProcessingReadiness(unready.id).canPrepare, isFalse);
      await w.sendWaitingNow();
      expect(f.modelRequests, isEmpty);
      expect(
        w.notes.map((n) => w.organizeStatus(n.id)),
        isNot(contains(OrganizeStatus.organized)),
      );
    },
  );
  test('real PDF text and table reach the same pipeline with source pages and raw bytes retained', () async {
    final f = BudgetFixture();
    await f.start();
    addTearDown(f.close);
    final w = f.workspaces.first;
    final note = await w.importPdf(original: File('test/fixtures/table.pdf'));
    final raw = await File(note.sourcePath).readAsString();
    final bytes = await File(note.attachments.single.originalPath)
        .readAsBytes();
    expect(note.document!.result!.tables, isNotEmpty);
    expect(note.document!.result!.tables.first.location.page, 1);
    expect(
      (await w.organizeNow(note.id)).status,
      TextProcessingStatus.completed,
    );
    final saved = w.notes.single;
    expect(saved.originalText, raw);
    expect(await File(saved.sourcePath).readAsString(), raw);
    expect(
      await File(saved.attachments.single.originalPath).readAsBytes(),
      bytes,
    );
    expect(await File(saved.notePath).readAsString(), contains('table.pdf'));
    final input = jsonDecode(
      f.modelRequests.single['messages'].last['content'] as String,
    ) as Map;
    expect(input['text'], raw);
    await f.reopen(0);
    expect(
      f
          .workspaces
          .first
          .notes
          .single
          .document!
          .result!
          .tables
          .first
          .location
          .page,
      1,
    );
  });
  test('a capture can be re-extracted until it is sent, and the extracted text is what is sent', () async {
    final f = BudgetFixture();
    await f.start();
    addTearDown(f.close);
    final w = f.workspaces.first;
    final note = await w.importDocument(
      original: File('test/fixtures/word/body-table.docx'),
      options: const DocumentExtractionOptions(maximumTableCells: 1),
    );
    final limited = note.text;
    expect(w.canRetryDocumentExtraction(note.id), isTrue);
    final extracting = w.retryDocumentExtraction(note.id);
    expect(w.textProcessingReadiness(note.id).canPrepare, isFalse);
    // Not sent while it is being extracted.
    await w.sendWaitingNow();
    expect(f.modelRequests, isEmpty);
    final extracted = await extracting;
    expect(extracted.text, isNot(limited));
    expect(extracted.originalText, extracted.text);
    await w.organizeNow(note.id);
    final input = jsonDecode(
      f.modelRequests.single['messages'].last['content'] as String,
    ) as Map;
    expect(input['text'], extracted.text);
    expect(w.canRetryDocumentExtraction(note.id), isFalse);
    await expectLater(w.retryDocumentExtraction(note.id), throwsStateError);
    expect(
      await File(w.notes.single.sourcePath).readAsString(),
      extracted.text,
    );
  });
  test('an externally edited document body is never overwritten by an arriving model result', () async {
    final f = BudgetFixture();
    await f.start();
    addTearDown(f.close);
    final w = f.workspaces.first;
    final note = await w.importDocument(
      original: File('test/fixtures/word/body-table.docx'),
    );
    final original = await File(note.sourcePath).readAsString();
    final changed = (await File(
      note.notePath,
    ).readAsString()).replaceFirst('## 正文\n\n', '## 正文\n\n外部修改\n');
    f.beforeReply = () async {
      await File(note.notePath).writeAsString(changed);
    };
    expect((await w.organizeNow(note.id)).status, TextProcessingStatus.review);
    expect(await File(note.notePath).readAsString(), changed);
    expect(await File(note.sourcePath).readAsString(), original);
    expect(w.notes.single.text, note.text);
    await f.reopen(0);
    // Reopening reads the external edit (T24) and may update the footer's
    // 修改 time to the file's own time; everything above it stays as edited.
    String withoutTimes(String markdown) =>
        markdown.replaceFirst(RegExp(r'\n记录：[^\n]*\n$'), '\n');
    final reopened = f.workspaces.first.notes.single;
    expect(
      withoutTimes(await File(reopened.notePath).readAsString()),
      withoutTimes(changed),
    );
    expect(reopened.text, startsWith('外部修改\n'));
    expect(f.modelRequests.length, 1);
  });
}
