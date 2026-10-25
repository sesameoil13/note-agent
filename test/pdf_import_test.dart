import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/note_workspace.dart';

void main() {
  test('embedded Chinese glyph shapes do not split or reorder a multiline table cell', () async {
    final root = await Directory.systemTemp.createTemp('pdf-embedded-font-');
    addTearDown(() => root.delete(recursive: true));
    final vault = await Directory('${root.path}/vault').create();
    final workspace = await NoteWorkspace.open(
      localDirectory: Directory('${root.path}/local'),
      vaultDirectory: vault,
    );
    addTearDown(workspace.close);
    final note = await workspace.importPdf(
      original: File('test/fixtures/embedded-font-table.pdf'),
    );
    expect(note.document!.result!.tables.single.rows[2][2].text, '第一行\n第二行');
    expect(note.text, contains('| 茶叶 |  | 第一行<br>第二行 |'));
  });
  test(
    'a second retry cannot start another extraction of the same PDF note',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'pdf-concurrent-retry-',
      );
      addTearDown(() => root.delete(recursive: true));
      final vault = await Directory('${root.path}/vault').create();
      final workspace = await NoteWorkspace.open(
        localDirectory: Directory('${root.path}/local'),
        vaultDirectory: vault,
      );
      addTearDown(workspace.close);
      final note = await workspace.importPdf(
        original: File('test/fixtures/chinese.pdf'),
      );
      final first = workspace.retryDocumentExtraction(note.id);
      await expectLater(
        workspace.retryDocumentExtraction(note.id),
        throwsStateError,
      );
      expect((await first).document!.status, DocumentImportStatus.ready);
      expect(workspace.notes, hasLength(1));
    },
  );
  test('excessive ruling geometry is bounded while the available text is preserved', () async {
    final root = await Directory.systemTemp.createTemp('pdf-geometry-');
    addTearDown(() => root.delete(recursive: true));
    final vault = await Directory('${root.path}/vault').create();
    final workspace = await NoteWorkspace.open(
      localDirectory: Directory('${root.path}/local'),
      vaultDirectory: vault,
    );
    addTearDown(workspace.close);
    final note = await workspace.importPdf(
      original: File('test/fixtures/dense-layout.pdf'),
    );
    expect(note.text, contains('复杂版面仍然保留原文。'));
    expect(note.document!.result!.tables, isEmpty);
    expect(note.document!.result!.completion, DocumentCompletion.partial);
    expect(
      note.document!.result!.problems.map((p) => p.code),
      contains('layoutLimit'),
    );
  });
  test('an incomplete original save can be retried by selecting a readable PDF for the same note', () async {
    final root = await Directory.systemTemp.createTemp('pdf-original-retry-');
    addTearDown(() => root.delete(recursive: true));
    final vault = await Directory('${root.path}/vault').create();
    final workspace = await NoteWorkspace.open(
      localDirectory: Directory('${root.path}/local'),
      vaultDirectory: vault,
    );
    addTearDown(workspace.close);
    await expectLater(
      workspace.importPdf(original: File('${root.path}/missing.pdf')),
      throwsA(isA<FileSystemException>()),
    );
    final pending = workspace.notes.single;
    expect(pending.document!.status, DocumentImportStatus.originalFailed);
    final recovered = await workspace.retryDocumentExtraction(
      pending.id,
      original: File('test/fixtures/chinese.pdf'),
    );
    expect(recovered.id, pending.id);
    expect(recovered.status, NoteStatus.localSaved);
    expect(recovered.document!.result!.completion, DocumentCompletion.complete);
    expect(recovered.text, contains('中文资料：保留原文。 Latin 42'));
    expect(workspace.notes, hasLength(1));
  });
  test('re-extraction after a failed initial publication recovers the same saved PDF note', () async {
    final root = await Directory.systemTemp.createTemp('pdf-republish-');
    addTearDown(() => root.delete(recursive: true));
    final vault = await Directory('${root.path}/vault').create();
    final local = Directory('${root.path}/local');
    final workspace = await NoteWorkspace.open(
      localDirectory: local,
      vaultDirectory: vault,
      filePublisher: _UnavailablePublisher(),
    );
    final note = await workspace.importPdf(
      original: File('test/fixtures/chinese.pdf'),
    );
    expect(note.status, NoteStatus.exportFailed);
    await workspace.close();
    final reopened = await NoteWorkspace.open(
      localDirectory: local,
      vaultDirectory: vault,
    );
    addTearDown(reopened.close);
    final recovered = await reopened.retryDocumentExtraction(note.id);
    expect(recovered.id, note.id);
    expect(recovered.status, NoteStatus.localSaved);
    expect(recovered.document!.status, DocumentImportStatus.ready);
    expect(
      await File(recovered.notePath).readAsString(),
      contains('中文资料：保留原文。 Latin 42'),
    );
    expect(reopened.notes, hasLength(1));
    expect(
      await File(recovered.attachments.single.sourcePath).readAsBytes(),
      await File('test/fixtures/chinese.pdf').readAsBytes(),
    );
  });
  test('re-extraction preserves associations and reports an edited body without replacing it', () async {
    final root = await Directory.systemTemp.createTemp('pdf-edit-');
    addTearDown(() => root.delete(recursive: true));
    final vault = await Directory('${root.path}/vault').create();
    final workspace = await NoteWorkspace.open(
      localDirectory: Directory('${root.path}/local'),
      vaultDirectory: vault,
    );
    addTearDown(workspace.close);
    final note = await workspace.importPdf(
      original: File('test/fixtures/chinese.pdf'),
    );
    final file = File(note.notePath);
    await file.writeAsString(
      (await file.readAsString()).replaceFirst('暂无关联', '[[研究资料]]'),
      flush: true,
    );
    final repeated = await workspace.retryDocumentExtraction(note.id);
    expect(repeated.document!.status, DocumentImportStatus.ready);
    expect(await file.readAsString(), contains('[[研究资料]]'));
    final edited = (await file.readAsString()).replaceFirst(
      '中文资料：保留原文。',
      '用户改写的正文。',
    );
    await file.writeAsString(edited, flush: true);
    final conflict = await workspace.retryDocumentExtraction(note.id);
    expect(conflict.document!.status, DocumentImportStatus.interrupted);
    expect(conflict.document!.error, contains('其他位置修改'));
    expect(await file.readAsString(), edited);
    expect(workspace.notes, hasLength(1));
    await file.rename('${file.path}.moved');
    final unavailable = await workspace.retryDocumentExtraction(note.id);
    expect(unavailable.document!.status, DocumentImportStatus.interrupted);
    expect(unavailable.document!.error, contains('无法读取笔记'));
  });
  test('page, character and elapsed limits report the remaining source instead of silently truncating', () async {
    final root = await Directory.systemTemp.createTemp('pdf-bounds-');
    addTearDown(() => root.delete(recursive: true));
    final vault = await Directory('${root.path}/vault').create();
    final workspace = await NoteWorkspace.open(
      localDirectory: Directory('${root.path}/local'),
      vaultDirectory: vault,
    );
    addTearDown(workspace.close);
    final pages = await workspace.importPdf(
      original: File('test/fixtures/many-pages.pdf'),
      options: const DocumentExtractionOptions(maximumPages: 1),
    );
    expect(pages.document!.result!.completion, DocumentCompletion.partial);
    expect(pages.document!.result!.processedPages, 1);
    expect(pages.document!.result!.totalPages, 50);
    expect(pages.document!.result!.problems.single.page, 2);
    expect(pages.document!.result!.problems.single.lastPage, 50);
    expect(pages.document!.result!.unprocessed.single.toJson()['lastPage'], 50);
    final dense = await workspace.importPdf(
      original: File('test/fixtures/chinese.pdf'),
      options: const DocumentExtractionOptions(maximumPageCharacters: 4),
    );
    expect(dense.document!.result!.problems.single.code, 'characterLimit');
    expect(dense.document!.result!.completion, DocumentCompletion.failed);
    final elapsed = await workspace.importPdf(
      original: File('test/fixtures/many-pages.pdf'),
      options: const DocumentExtractionOptions(
        timeBudget: Duration(microseconds: 1),
      ),
    );
    expect(elapsed.document!.result!.problems.single.code, 'timeLimit');
    expect(
      await File(elapsed.attachments.single.originalPath).exists(),
      isTrue,
    );
  });
  test('locked PDF is distinguished from damage without asking or persisting a password', () async {
    final root = await Directory.systemTemp.createTemp('pdf-locked-');
    addTearDown(() => root.delete(recursive: true));
    final vault = await Directory('${root.path}/vault').create();
    final workspace = await NoteWorkspace.open(
      localDirectory: Directory('${root.path}/local'),
      vaultDirectory: vault,
    );
    addTearDown(workspace.close);
    final original = File('test/fixtures/locked.pdf');
    final note = await workspace.importPdf(original: original);
    expect(note.document!.result!.problems.single.code, 'passwordRequired');
    expect(note.document!.result!.completion, DocumentCompletion.failed);
    expect(note.document!.result!.markdown, isEmpty);
    expect(
      await File(note.attachments.single.originalPath).readAsBytes(),
      await original.readAsBytes(),
    );
    expect(await File(note.notePath).readAsString(), contains('本次未尝试密码'));
  });
  test('prose columns and an incomplete table grid remain text without invented cells', () async {
    final root = await Directory.systemTemp.createTemp('pdf-layout-');
    addTearDown(() => root.delete(recursive: true));
    final vault = await Directory('${root.path}/vault').create();
    final workspace = await NoteWorkspace.open(
      localDirectory: Directory('${root.path}/local'),
      vaultDirectory: vault,
    );
    addTearDown(workspace.close);
    final columns = await workspace.importPdf(
      original: File('test/fixtures/columns.pdf'),
    );
    expect(columns.document!.result!.tables, isEmpty);
    expect(columns.text, contains('左栏第一段完整保留。'));
    expect(columns.text, contains('右栏第二段原文。'));
    final irregular = await workspace.importPdf(
      original: File('test/fixtures/irregular.pdf'),
    );
    expect(irregular.document!.result!.tables, isEmpty);
    expect(irregular.document!.result!.completion, DocumentCompletion.partial);
    expect(
      irregular.document!.result!.problems.map((p) => p.code),
      contains('unsupportedLayout'),
    );
    for (final text in ['合并单元格内容', '第一项', '第二项', '第三项', '第四项']) {
      expect(irregular.text, contains(text));
    }
  });
  test(
    'mixed image pages retain searchable text and mark every page needing OCR',
    () async {
      final root = await Directory.systemTemp.createTemp('pdf-mixed-');
      addTearDown(() => root.delete(recursive: true));
      final vault = await Directory('${root.path}/vault').create();
      final workspace = await NoteWorkspace.open(
        localDirectory: Directory('${root.path}/local'),
        vaultDirectory: vault,
      );
      addTearDown(workspace.close);
      final note = await workspace.importPdf(
        original: File('test/fixtures/mixed.pdf'),
      );
      expect(note.document!.result!.completion, DocumentCompletion.partial);
      expect(note.document!.result!.unprocessed.map((p) => p.page), [1, 2]);
      expect(workspace.search('可检索的文字页面').single.id, note.id);
    },
  );
  test('retrying note publication after restart restores the oversized PDF source entry', () async {
    final root = await Directory.systemTemp.createTemp('pdf-publication-');
    addTearDown(() => root.delete(recursive: true));
    final vault = await Directory('${root.path}/vault').create();
    final local = Directory('${root.path}/local');
    final large = await File('test/fixtures/chinese.pdf')
        .copy('${root.path}/retained-large.pdf');
    final handle = await large.open(mode: FileMode.append);
    await handle.truncate(5000001);
    await handle.close();
    final workspace = await NoteWorkspace.open(
      localDirectory: local,
      vaultDirectory: vault,
      filePublisher: _UnavailablePublisher(),
    );
    final note = await workspace.importPdf(original: large);
    expect(note.status, NoteStatus.exportFailed);
    await workspace.close();
    final reopened = await NoteWorkspace.open(
      localDirectory: local,
      vaultDirectory: vault,
    );
    addTearDown(reopened.close);
    final retried = await reopened.retryNoteExport(note.id);
    expect(retried.status, NoteStatus.localSaved);
    expect(
      await File(retried.notePath).readAsString(),
      contains('retained-large.pdf（仅本机保留'),
    );
    expect(reopened.notes, hasLength(1));
  });
  test('Sync size and extraction size remain independent and a smaller copy never replaces the extraction original', () async {
    final root = await Directory.systemTemp.createTemp('pdf-size-');
    addTearDown(() => root.delete(recursive: true));
    final vault = await Directory('${root.path}/vault').create();
    final workspace = await NoteWorkspace.open(
      localDirectory: Directory('${root.path}/local'),
      vaultDirectory: vault,
    );
    addTearDown(workspace.close);
    final large = await File('test/fixtures/chinese.pdf')
        .copy('${root.path}/large.pdf');
    final handle = await large.open(mode: FileMode.append);
    await handle.truncate(5000001);
    await handle.close();
    final note = await workspace.importPdf(original: large);
    expect(note.document!.result!.completion, DocumentCompletion.complete);
    expect(note.attachments.single.status, AttachmentStatus.exceedsFileLimit);
    expect(note.syncStatus, NoteSyncStatus.attachmentBlocked);
    expect(
      await File(note.attachments.single.originalPath).readAsBytes(),
      await large.readAsBytes(),
    );
    await workspace.chooseAttachmentCopy(
      attachmentId: note.attachments.single.id,
      copy: File('test/fixtures/scan.pdf'),
    );
    final retried = await workspace.retryDocumentExtraction(note.id);
    expect(retried.text, contains('保留原文'));
    expect(retried.attachments.single.originalByteLength, 5000001);
    expect(retried.attachments.single.originalPublished, isFalse);
    final huge = await File('test/fixtures/chinese.pdf')
        .copy('${root.path}/huge.pdf');
    final hugeHandle = await huge.open(mode: FileMode.append);
    await hugeHandle.truncate(32 * 1024 * 1024 + 1);
    await hugeHandle.close();
    final limited = await workspace.importPdf(original: huge);
    expect(limited.document!.result!.problems.single.code, 'inputLimit');
    expect(limited.document!.result!.completion, DocumentCompletion.failed);
    expect(
      await File(limited.attachments.single.originalPath).length(),
      32 * 1024 * 1024 + 1,
    );
  });
  test('serialized table output obeys the output budget and identifies the unprocessed page', () async {
    final root = await Directory.systemTemp.createTemp('pdf-output-limit-');
    addTearDown(() => root.delete(recursive: true));
    final vault = await Directory('${root.path}/vault').create();
    final workspace = await NoteWorkspace.open(
      localDirectory: Directory('${root.path}/local'),
      vaultDirectory: vault,
    );
    addTearDown(workspace.close);
    final note = await workspace.importPdf(
      original: File('test/fixtures/table.pdf'),
      options: const DocumentExtractionOptions(maximumCharacters: 85),
    );
    expect(
      note.document!.result!.problems.map((p) => p.code),
      contains('outputLimit'),
      reason: note.document!.result!.markdown.length.toString(),
    );
    expect(note.document!.result!.completion, DocumentCompletion.failed);
    expect(note.document!.result!.unprocessed.single.page, 1);
    expect(note.document!.result!.markdown.length, lessThanOrEqualTo(85));
  });
  test(
    'damaged PDF keeps its original and retries the same note after restart',
    () async {
      final root = await Directory.systemTemp.createTemp('pdf-damaged-');
      addTearDown(() => root.delete(recursive: true));
      final vault = await Directory('${root.path}/vault').create();
      final local = Directory('${root.path}/local');
      final original = await File('${root.path}/damaged.pdf')
          .writeAsString('%PDF-1.7\ntruncated invalid objects');
      final workspace = await NoteWorkspace.open(
        localDirectory: local,
        vaultDirectory: vault,
      );
      final note = await workspace.importPdf(original: original);
      expect(note.document!.result!.completion, DocumentCompletion.failed);
      expect(note.document!.result!.problems.single.code, 'damagedPdf');
      await workspace.close();
      final reopened = await NoteWorkspace.open(
        localDirectory: local,
        vaultDirectory: vault,
      );
      addTearDown(reopened.close);
      final retried = await reopened.retryDocumentExtraction(note.id);
      expect(retried.id, note.id);
      expect(reopened.notes, hasLength(1));
      expect(retried.document!.result!.completion, DocumentCompletion.failed);
      expect(
        await File(retried.attachments.single.originalPath).readAsBytes(),
        await original.readAsBytes(),
      );
    },
  );
  test('scan is retained with an explicit unextracted status rather than empty success', () async {
    final root = await Directory.systemTemp.createTemp('pdf-scan-');
    addTearDown(() => root.delete(recursive: true));
    final vault = await Directory('${root.path}/vault').create();
    final workspace = await NoteWorkspace.open(
      localDirectory: Directory('${root.path}/local'),
      vaultDirectory: vault,
    );
    addTearDown(workspace.close);
    final note = await workspace.importPdf(
      original: File('test/fixtures/scan.pdf'),
    );
    expect(
      note.document!.result!.completion,
      DocumentCompletion.noExtractableText,
    );
    expect(note.document!.result!.unprocessed.single.page, 1);
    expect(note.document!.result!.body, isEmpty);
    expect(
      await File(note.attachments.single.originalPath).readAsBytes(),
      await File('test/fixtures/scan.pdf').readAsBytes(),
    );
    expect(await File(note.notePath).readAsString(), contains('尚未 OCR'));
  });
  test('PDF rule grid becomes a traceable table without repeating or dropping cell text', () async {
    final root = await Directory.systemTemp.createTemp('pdf-table-');
    addTearDown(() => root.delete(recursive: true));
    final vault = await Directory('${root.path}/vault').create();
    final workspace = await NoteWorkspace.open(
      localDirectory: Directory('${root.path}/local'),
      vaultDirectory: vault,
    );
    addTearDown(workspace.close);
    final note = await workspace.importPdf(
      original: File('test/fixtures/table.pdf'),
    );
    final result = note.document!.result!;
    expect(result.tables, hasLength(1));
    expect(
      result.tables.single.rows
          .map((r) => r.map((c) => c.text).toList())
          .toList(),
      [
        ['产品', '数量', '备注'],
        ['苹果', '2', 'A | B'],
        ['茶叶', '', '第一行\n第二行'],
      ],
    );
    expect(result.tables.single.rows[2][1].location.bounds, [
      160,
      560,
      280,
      600,
    ]);
    expect(result.tables.single.location.page, 1);
    expect(note.text, contains('| 苹果 | 2 | A &#124; B |'));
    expect(note.text, contains('| 茶叶 |  | 第一行<br>第二行 |'));
    expect('苹果'.allMatches(note.text), hasLength(1));
    expect(note.text.indexOf('采购资料'), lessThan(note.text.indexOf('| 产品')));
    expect(note.text.indexOf('表格后的原文'), greaterThan(note.text.indexOf('| 茶叶')));
    expect(
      await File(note.notePath).readAsString(),
      contains('| 产品 | 数量 | 备注 |'),
    );
  });
  test(
    'PDF Chinese text and its original survive restart as an ordinary note',
    () async {
      final root = await Directory.systemTemp.createTemp('pdf-workspace-');
      addTearDown(() => root.delete(recursive: true));
      final local = Directory('${root.path}/local');
      final vault = await Directory('${root.path}/vault').create();
      final original = File('test/fixtures/chinese.pdf');
      final workspace = await NoteWorkspace.open(
        localDirectory: local,
        vaultDirectory: vault,
      );
      final note = await workspace.importPdf(original: original);
      expect(
        note.document!.result!.completion,
        DocumentCompletion.complete,
        reason: note.document!.result!.toJson().toString(),
      );
      expect(note.text, contains('中文资料：保留原文。 Latin 42'));
      expect(workspace.search('保留原文').single.id, note.id);
      expect(note.document!.result!.body.single.location.page, 1);
      expect(
        await File(note.attachments.single.originalPath).readAsBytes(),
        await original.readAsBytes(),
      );
      final markdown = await File(note.notePath).readAsString();
      expect(
        RegExp(
          r'^## .+$',
          multiLine: true,
        ).allMatches(markdown).map((m) => m[0]),
        ['## 正文', '## 关联', '## 来源'],
      );
      expect(markdown, contains('chinese.pdf'));
      await workspace.close();
      final reopened = await NoteWorkspace.open(
        localDirectory: local,
        vaultDirectory: vault,
      );
      addTearDown(reopened.close);
      expect(
        reopened.notes.single.document!.result!.completion,
        DocumentCompletion.complete,
      );
      expect(reopened.search('Latin 42').single.id, note.id);
      expect(
        await File(reopened.notes.single.attachments.single.originalPath)
            .exists(),
        isTrue,
      );
    },
  );
}

class _UnavailablePublisher implements NoteFilePublisher {
  @override
  Future<void> publish({
    required File destination,
    required File staging,
    required String text,
  }) async => throw const FileSystemException('Test vault unavailable');
}
