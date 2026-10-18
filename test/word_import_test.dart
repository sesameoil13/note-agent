import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/note_workspace.dart';

void main() {
  test('Word body and tables remain in source order with stable part locations and original', () async {
    final root = await Directory.systemTemp.createTemp('word-import-');
    addTearDown(() => root.delete(recursive: true));
    final vault = await Directory('${root.path}/vault').create();
    final workspace = await NoteWorkspace.open(
      localDirectory: Directory('${root.path}/local'),
      vaultDirectory: vault,
    );
    addTearDown(workspace.close);
    final file = File('test/fixtures/word/body-table.docx');
    final note = await workspace.importDocument(original: file);
    final result = note.document!.result!;
    expect(result.completion, DocumentCompletion.complete);
    expect(
      note.text,
      '中文资料：随口记录想法。 Latin 42 😀\n\n| 产品 | 数量 | 备注 |\n| --- | --- | --- |\n| 苹果 | 2 | A &#124; B |\n| 茶叶 |  | 第一行<br>第二行 |\n\n表格后的原文。',
    );
    expect(result.body.map((b) => b.location.blockIndex), [0, 2]);
    expect(result.tables.single.location.blockIndex, 1);
    expect(
      result.tables.single.rows[2][2].location.part,
      'word/document.xml#block=1/row=2/cell=2',
    );
    expect(result.totalPages, 0);
    expect(
      result.body.every(
        (b) => b.location.page == null && b.location.bounds == null,
      ),
      isTrue,
    );
    final source = workspace.attachments.single;
    expect(
      await File(source.originalPath).readAsBytes(),
      await file.readAsBytes(),
    );
    expect(
      await File(source.sourcePath).readAsBytes(),
      await file.readAsBytes(),
    );
    expect(workspace.search('表格后的').single.id, note.id);
    final markdown = await File(note.notePath).readAsString();
    expect(
      RegExp(
        r'^## .+$',
        multiLine: true,
      ).allMatches(markdown).map((m) => m.group(0)),
      ['## 正文', '## 关联', '## 来源'],
    );
    expect(markdown, isNot(contains('## 摘要')));
  });
  test('Word pictures and additional stories are explicit unprocessed regions without a claim of OCR', () async {
    final root = await Directory.systemTemp.createTemp('word-mixed-');
    addTearDown(() => root.delete(recursive: true));
    final vault = await Directory('${root.path}/vault').create();
    final workspace = await NoteWorkspace.open(
      localDirectory: Directory('${root.path}/local'),
      vaultDirectory: vault,
    );
    addTearDown(workspace.close);
    final note = await workspace.importDocument(
      original: File('test/fixtures/word/mixed.docx'),
    );
    final result = note.document!.result!;
    expect(result.completion, DocumentCompletion.partial);
    expect(note.text, '配图前的文字。\n\n配图后的文字。');
    expect(
      result.problems.map((p) => p.code),
      containsAll(['imageRegion', 'unsupportedStory']),
    );
    expect(result.unprocessed.any((r) => r.part == 'word/header1.xml'), isTrue);
    final image = await workspace.importDocument(
      original: File('test/fixtures/word/images-only.docx'),
    );
    expect(
      image.document!.result!.completion,
      DocumentCompletion.noExtractableText,
    );
    expect(image.document!.result!.problems.single.code, 'imageRegion');
    expect(
      image.document!.result!.unprocessed.single.part,
      'word/document.xml',
    );
    expect(
      await File(workspace.attachments.last.originalPath).exists(),
      isTrue,
    );
  });
  test('merged and nested Word tables preserve text once and explicitly avoid pretending layout is complete', () async {
    final root = await Directory.systemTemp.createTemp('word-complex-');
    addTearDown(() => root.delete(recursive: true));
    final vault = await Directory('${root.path}/vault').create();
    final workspace = await NoteWorkspace.open(
      localDirectory: Directory('${root.path}/local'),
      vaultDirectory: vault,
    );
    addTearDown(workspace.close);
    final note = await workspace.importDocument(
      original: File('test/fixtures/word/complex.docx'),
    );
    final result = note.document!.result!;
    expect(result.completion, DocumentCompletion.partial);
    expect(result.tables, isEmpty);
    for (final expected in ['跨列内容', '外层单元格', '嵌套内容']) {
      expect(expected.allMatches(note.text), hasLength(1));
    }
    expect(note.text.indexOf('复杂表格前。'), lessThan(note.text.indexOf('跨列内容')));
    expect(note.text.indexOf('复杂表格后。'), greaterThan(note.text.indexOf('嵌套内容')));
    expect(result.problems.map((p) => p.code), contains('complexTable'));
    expect(result.unprocessed.single.blockIndex, 1);
  });
  test('Word current revision text and cached fields stay readable while unsupported blocks are disclosed', () async {
    final root = await Directory.systemTemp.createTemp('word-revisions-');
    addTearDown(() => root.delete(recursive: true));
    final vault = await Directory('${root.path}/vault').create();
    final workspace = await NoteWorkspace.open(
      localDirectory: Directory('${root.path}/local'),
      vaultDirectory: vault,
    );
    addTearDown(workspace.close);
    final note = await workspace.importDocument(
      original: File('test/fixtures/word/revisions.docx'),
    );
    final result = note.document!.result!;
    expect(result.completion, DocumentCompletion.partial);
    expect(note.text, '当前段落新增文字字段缓存\n\n控件文字');
    expect(
      result.problems.map((p) => p.code),
      containsAll(['revisions', 'fieldResult', 'unsupportedBlock']),
    );
    final strict = await workspace.importDocument(
      original: File('test/fixtures/word/strict-renamed.docx'),
    );
    expect(strict.text, '严格命名空间和非默认主路径。');
    expect(
      strict.document!.result!.body.single.location.part,
      'custom/main.xml',
    );
  });
  test('Word output and table work stop at caller limits without losing the retained original', () async {
    final root = await Directory.systemTemp.createTemp('word-limits-');
    addTearDown(() => root.delete(recursive: true));
    final vault = await Directory('${root.path}/vault').create();
    final workspace = await NoteWorkspace.open(
      localDirectory: Directory('${root.path}/local'),
      vaultDirectory: vault,
    );
    addTearDown(workspace.close);
    final source = File('test/fixtures/word/body-table.docx');
    final limited = await workspace.importDocument(
      original: source,
      options: const DocumentExtractionOptions(maximumCharacters: 40),
    );
    expect(limited.text, '中文资料：随口记录想法。 Latin 42 😀');
    expect(limited.document!.result!.completion, DocumentCompletion.partial);
    expect(
      limited.document!.result!.problems.map((p) => p.code),
      contains('outputLimit'),
    );
    expect(limited.document!.result!.unprocessed.single.blockIndex, 1);
    final cells = await workspace.importDocument(
      original: source,
      options: const DocumentExtractionOptions(maximumTableCells: 2),
    );
    expect(cells.document!.result!.tables, isEmpty);
    expect(
      cells.document!.result!.problems.map((p) => p.code),
      contains('tableLimit'),
    );
    final attachment = workspace.attachments.firstWhere(
      (a) => a.noteId == cells.id,
    );
    expect(
      await File(attachment.originalPath).readAsBytes(),
      await source.readAsBytes(),
    );
  });
  test('cancel during Word import terminates parsing and retry reuses the retained source and note', () async {
    final root = await Directory.systemTemp.createTemp('word-cancel-');
    addTearDown(() => root.delete(recursive: true));
    final vault = await Directory('${root.path}/vault').create();
    final local = Directory('${root.path}/local');
    var workspace = await NoteWorkspace.open(
      localDirectory: local,
      vaultDirectory: vault,
    );
    addTearDown(() => workspace.close());
    final source = File('test/fixtures/word/long.docx');
    final operation = workspace.importDocument(original: source);
    while (workspace.notes.isEmpty ||
        workspace.notes.single.document!.status !=
            DocumentImportStatus.extracting) {
      await Future<void>.delayed(Duration.zero);
    }
    final id = workspace.notes.single.id;
    workspace.cancelDocumentExtraction(id);
    final cancelled = await operation;
    expect(cancelled.document!.result!.problems.single.code, 'cancelled');
    expect(cancelled.document!.result!.completion, DocumentCompletion.failed);
    final attachment = workspace.attachments.single;
    final recovered = await workspace.retryDocumentExtraction(
      id,
      options: const DocumentExtractionOptions(maximumCharacters: 30),
    );
    expect(recovered.id, id);
    expect(recovered.text, startsWith('第0段原文。'));
    expect(recovered.document!.result!.completion, DocumentCompletion.partial);
    expect(workspace.attachments.single.id, attachment.id);
    await workspace.close();
    workspace = await NoteWorkspace.open(
      localDirectory: local,
      vaultDirectory: vault,
    );
    expect(workspace.notes.single.id, id);
    expect(workspace.notes.single.text, recovered.text);
    expect(workspace.attachments.single.id, attachment.id);
    expect(
      await File(attachment.originalPath).readAsBytes(),
      await source.readAsBytes(),
    );
  });
  test('an output limit before the first Word block is a processing limit, never an image-only success', () async {
    final root = await Directory.systemTemp.createTemp('word-empty-limit-');
    addTearDown(() => root.delete(recursive: true));
    final workspace = await NoteWorkspace.open(
      localDirectory: Directory('${root.path}/local'),
      vaultDirectory: await Directory('${root.path}/vault').create(),
    );
    addTearDown(workspace.close);
    final note = await workspace.importDocument(
      original: File('test/fixtures/word/body-table.docx'),
      options: const DocumentExtractionOptions(maximumCharacters: 1),
    );
    expect(note.document!.result!.completion, DocumentCompletion.failed);
    expect(note.document!.result!.problems.single.code, 'outputLimit');
    expect(note.document!.result!.summary, isNot(contains('扫描件')));
  });
  test('Word corruption, untrusted package paths and XML expansion are rejected with originals retained', () async {
    final root = await Directory.systemTemp.createTemp('word-safety-');
    addTearDown(() => root.delete(recursive: true));
    final workspace = await NoteWorkspace.open(
      localDirectory: Directory('${root.path}/local'),
      vaultDirectory: await Directory('${root.path}/vault').create(),
    );
    addTearDown(workspace.close);
    const cases = {
      'broken.docx': 'damagedWord',
      'damaged-xml.docx': 'damagedWord',
      'undeclared-prefix.docx': 'damagedWord',
      'missing-main.docx': 'damagedWord',
      'duplicate.docx': 'damagedWord',
      'traversal.docx': 'damagedWord',
      'crc.docx': 'damagedWordCrc',
      'lying-size.docx': 'damagedWord',
      'encrypted.docx': 'encryptedWord',
      'legacy.doc': 'legacyOrEncrypted',
      'dtd.docx': 'unsafeXml',
      'deep.docx': 'xmlLimit',
      'expanded-limit.docx': 'xmlLimit',
      'entry-limit.docx': 'packageLimit',
    };
    for (final entry in cases.entries) {
      final source = File('test/fixtures/word/${entry.key}');
      final note = await workspace.importDocument(original: source);
      expect(
        note.document!.result!.completion,
        DocumentCompletion.failed,
        reason: entry.key,
      );
      expect(
        note.document!.result!.problems.single.code,
        entry.value,
        reason: entry.key,
      );
      final attachment = workspace.attachments.firstWhere(
        (a) => a.noteId == note.id,
      );
      expect(
        await File(attachment.originalPath).readAsBytes(),
        await source.readAsBytes(),
        reason: entry.key,
      );
      expect(note.text, '尚未提取正文。', reason: entry.key);
    }
    expect(workspace.notes, hasLength(cases.length));
  });

  test(
    'Word input and time limits terminate locally without removing the source',
    () async {
      final root = await Directory.systemTemp.createTemp('word-deadline-');
      addTearDown(() => root.delete(recursive: true));
      final workspace = await NoteWorkspace.open(
        localDirectory: Directory('${root.path}/local'),
        vaultDirectory: await Directory('${root.path}/vault').create(),
      );
      addTearDown(workspace.close);
      final source = File('test/fixtures/word/long.docx');
      final input = await workspace.importDocument(
        original: source,
        options: const DocumentExtractionOptions(maximumInputBytes: 16),
      );
      expect(input.document!.result!.problems.single.code, 'inputLimit');
      final start = Stopwatch()..start();
      final time = await workspace.importDocument(
        original: source,
        options: const DocumentExtractionOptions(
          timeBudget: Duration(microseconds: 1),
        ),
      );
      expect(time.document!.result!.problems.single.code, 'timeLimit');
      expect(start.elapsed, lessThan(const Duration(seconds: 5)));
      expect(workspace.attachments, hasLength(2));
      for (final a in workspace.attachments) {
        expect(
          await File(a.originalPath).readAsBytes(),
          await source.readAsBytes(),
        );
      }
    },
  );
  test('streamed Word ZIP descriptors must agree with validated content and UTF16 XML remains readable', () async {
    final root = await Directory.systemTemp.createTemp('word-streamed-');
    addTearDown(() => root.delete(recursive: true));
    final workspace = await NoteWorkspace.open(
      localDirectory: Directory('${root.path}/local'),
      vaultDirectory: await Directory('${root.path}/vault').create(),
    );
    addTearDown(workspace.close);
    final good = await workspace.importDocument(
      original: File('test/fixtures/word/streamed.docx'),
    );
    expect(good.document!.result!.completion, DocumentCompletion.complete);
    expect(good.text, contains('第一行<br>第二行'));
    final bad = await workspace.importDocument(
      original: File('test/fixtures/word/bad-descriptor.docx'),
    );
    expect(bad.document!.result!.completion, DocumentCompletion.failed);
    final utf16 = await workspace.importDocument(
      original: File('test/fixtures/word/utf16.docx'),
    );
    expect(utf16.text, 'UTF16 中文来源 😀');
    expect(utf16.document!.result!.completion, DocumentCompletion.complete);
  });
  test('alternative Word branches do not duplicate text and generated list numbering is disclosed', () async {
    final root = await Directory.systemTemp.createTemp('word-alternate-');
    addTearDown(() => root.delete(recursive: true));
    final workspace = await NoteWorkspace.open(
      localDirectory: Directory('${root.path}/local'),
      vaultDirectory: await Directory('${root.path}/vault').create(),
    );
    addTearDown(workspace.close);
    final note = await workspace.importDocument(
      original: File('test/fixtures/word/alternate.docx'),
    );
    expect(note.text, '替代内容：主分支文字\n\n列表正文‑续文');
    expect(note.document!.result!.completion, DocumentCompletion.partial);
    expect(
      note.document!.result!.problems.map((p) => p.code),
      containsAll(['unsupportedBlock', 'listNumbering']),
    );
  });
  test('oversized Word remains extractable locally while Standard publication is withheld and the retained original never changes', () async {
    final root = await Directory.systemTemp.createTemp('word-standard-limit-');
    addTearDown(() => root.delete(recursive: true));
    final workspace = await NoteWorkspace.open(
      localDirectory: Directory('${root.path}/local'),
      vaultDirectory: await Directory('${root.path}/vault').create(),
    );
    addTearDown(workspace.close);
    final archive = ZipDecoder().decodeBytes(
      await File('test/fixtures/word/body-table.docx').readAsBytes(),
    );
    archive.add(
      ArchiveFile('word/media/unread.bin', 5000001, Uint8List(5000001)),
    );
    final source = await File('${root.path}/较大文档.docx')
        .writeAsBytes(ZipEncoder().encode(archive, level: 0));
    expect(await source.length(), greaterThan(5000000));
    final note = await workspace.importDocument(original: source);
    expect(note.document!.result!.completion, DocumentCompletion.complete);
    expect(note.text, contains('表格后的原文。'));
    final attachment = workspace.attachments.single;
    expect(attachment.status, AttachmentStatus.exceedsFileLimit);
    expect(attachment.originalPublished, isFalse);
    expect(
      await File(attachment.originalPath).readAsBytes(),
      await source.readAsBytes(),
    );
    expect(await File(attachment.sourcePath).exists(), isFalse);
    final retried = await workspace.retryDocumentExtraction(note.id);
    expect(retried.id, note.id);
    expect(workspace.attachments.single.id, attachment.id);
    expect(workspace.notes, hasLength(1));
  });

  test('Word re-extraction preserves a separately edited note and never replaces its original', () async {
    final root = await Directory.systemTemp.createTemp('word-edited-');
    addTearDown(() => root.delete(recursive: true));
    final workspace = await NoteWorkspace.open(
      localDirectory: Directory('${root.path}/local'),
      vaultDirectory: await Directory('${root.path}/vault').create(),
    );
    addTearDown(workspace.close);
    final source = File('test/fixtures/word/body-table.docx');
    final note = await workspace.importDocument(original: source);
    final file = File(note.notePath);
    final edited = (await file.readAsString()).replaceFirst(
      '中文资料：随口记录想法。',
      '用户在 Obsidian 中修改的正文。',
    );
    await file.writeAsString(edited, flush: true);
    final retried = await workspace.retryDocumentExtraction(note.id);
    expect(retried.document!.status, DocumentImportStatus.interrupted);
    expect(retried.document!.error, contains('其他位置修改'));
    expect(await file.readAsString(), edited);
    expect(workspace.notes.single.id, note.id);
    expect(
      await File(workspace.attachments.single.originalPath).readAsBytes(),
      await source.readAsBytes(),
    );
  });
  test('Word package part equivalence rejects case aliases and resolves mixed-case references', () async {
    final root = await Directory.systemTemp.createTemp('word-case-');
    addTearDown(() => root.delete(recursive: true));
    final workspace = await NoteWorkspace.open(
      localDirectory: Directory('${root.path}/local'),
      vaultDirectory: await Directory('${root.path}/vault').create(),
    );
    addTearDown(workspace.close);
    final duplicate = await workspace.importDocument(
      original: File('test/fixtures/word/case-duplicate.docx'),
    );
    expect(duplicate.document!.result!.completion, DocumentCompletion.failed);
    final cased = await workspace.importDocument(
      original: File('test/fixtures/word/case-reference.docx'),
    );
    expect(cased.document!.result!.completion, DocumentCompletion.complete);
    expect(cased.text, contains('表格后的原文。'));
  });
}
