import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/note_workspace.dart';

void main() {
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
