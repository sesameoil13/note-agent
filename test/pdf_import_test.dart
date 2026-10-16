import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/note_workspace.dart';

void main() {
  test('scan is retained with an explicit unextracted status rather than empty success', () async {
    final root = await Directory.systemTemp.createTemp('pdf-scan-');
    addTearDown(() => root.delete(recursive: true));
    final vault = await Directory('${root.path}/vault').create();
    final workspace = await NoteWorkspace.open(localDirectory: Directory('${root.path}/local'), vaultDirectory: vault);
    addTearDown(workspace.close);
    final note = await workspace.importPdf(original: File('test/fixtures/scan.pdf'));
    expect(note.document!.result!.completion, DocumentCompletion.noExtractableText);
    expect(note.document!.result!.unprocessed.single.page, 1);
    expect(note.document!.result!.body, isEmpty);
    expect(await File(note.attachments.single.originalPath).readAsBytes(), await File('test/fixtures/scan.pdf').readAsBytes());
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
