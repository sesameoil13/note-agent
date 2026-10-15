import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/note_workspace.dart';

void main() {
  late Directory temporary;
  late Directory local;
  late Directory vault;
  late NoteWorkspace workspace;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('note-agent-t04-');
    local = Directory('${temporary.path}/local');
    vault = await Directory('${temporary.path}/vault').create();
    vault = Directory(await vault.resolveSymbolicLinks());
    var nextId = 0;
    workspace = await NoteWorkspace.open(
      localDirectory: local,
      vaultDirectory: vault,
      createId: () => 'record-${++nextId}',
      clock: () => DateTime(2026, 10, 15, 10, nextId),
    );
  });

  tearDown(() async {
    await workspace.close();
    await temporary.delete(recursive: true);
  });

  test(
    'find collected original text by title or keywords after restart',
    () async {
      await workspace.captureText(title: '设计观察', text: '保留完整原文。\n排版使用八点网格。');
      await workspace.captureText(title: '客户反馈', text: '标题之外的检索关键词：离线。');
      await workspace.captureText(
        title: 'API 记录',
        text: 'Case insensitive retrieval.',
      );
      await workspace.close();
      workspace = await NoteWorkspace.open(
        localDirectory: local,
        vaultDirectory: vault,
      );

      expect(workspace.search('  设计  ').single.title, '设计观察');
      final found = workspace.search('离线').single;
      expect(found.text, '标题之外的检索关键词：离线。');
      expect(await File(found.sourcePath).readAsString(), found.text);
      expect(await File(found.notePath).readAsString(), contains(found.text));
      expect(workspace.search('case').single.title, 'API 记录');
      expect(workspace.search('不存在'), isEmpty);
      expect(workspace.search('').map((note) => note.title), [
        'API 记录',
        '客户反馈',
        '设计观察',
      ]);
    },
  );

  test(
    'try supplied semantic titles before numbering duplicates without blocking',
    () async {
      final existing = File('${vault.path}/会议记录.md');
      await existing.writeAsString('用户已有的会议记录');
      final semantic = await workspace.captureText(
        title: '会议记录',
        semanticTitleCandidates: ['会议记录', '客户会议要点'],
        text: '客户讨论了新需求。',
      );
      expect(semantic.title, '客户会议要点');
      expect(semantic.titleCollision, isFalse);
      final duplicate = await workspace.captureText(
        title: '会议记录',
        semanticTitleCandidates: ['客户会议要点'],
        text: '另一份原文。',
      );
      expect(duplicate.title, '会议记录 (2)');
      expect(duplicate.titleCollision, isTrue);
      expect(duplicate.status, NoteStatus.localSaved);
      final next = await workspace.captureText(title: '会议记录', text: '第三份原文。');
      expect(next.title, '会议记录 (3)');
      expect(await existing.readAsString(), '用户已有的会议记录');
      await workspace.close();
      workspace = await NoteWorkspace.open(
        localDirectory: local,
        vaultDirectory: vault,
      );
      expect(workspace.search('另一份').single.titleCollision, isTrue);
      expect(workspace.notes, hasLength(3));
    },
  );

  test('rename Chinese title preserves original, inbound links and restart retrieval', () async {
    final note = await workspace.captureText(title: '产品观察', text: '原文保持不变。');
    final inbound = File('${vault.path}/索引.md');
    await inbound.writeAsString('''[[产品观察]] [[产品观察#正文|阅读]] ![[产品观察]]
[打开](产品观察.md) [定位](<产品观察.md#正文>)
[编码](%E4%BA%A7%E5%93%81%E8%A7%82%E5%AF%9F.md)
[[产品观察补充]] [外部](https://example.com/产品观察.md)
`[[产品观察]]`
```
[[产品观察]]
```
''');
    final folder = await Directory('${vault.path}/资料').create();
    final nested = File('${folder.path}/入站.md');
    await nested.writeAsString('[引用](../产品观察.md#正文)');
    final existing = File('${vault.path}/中文新标题.md');
    await existing.writeAsString('保留同名文件');

    final renamed = await workspace.renameNote(note.id, title: '中文新标题');
    expect(renamed.id, note.id);
    expect(renamed.title, '中文新标题 (2)');
    expect(renamed.titleCollision, isTrue);
    expect(renamed.createdAt, note.createdAt);
    expect(await existing.readAsString(), '保留同名文件');
    expect(await File(note.notePath).exists(), isFalse);
    expect(await File(renamed.sourcePath).readAsString(), '原文保持不变。');
    expect(
      await inbound.readAsString(),
      '''[[中文新标题 (2)]] [[中文新标题 (2)#正文|阅读]] ![[中文新标题 (2)]]
[打开](%E4%B8%AD%E6%96%87%E6%96%B0%E6%A0%87%E9%A2%98%20(2).md) [定位](<中文新标题 (2).md#正文>)
[编码](%E4%B8%AD%E6%96%87%E6%96%B0%E6%A0%87%E9%A2%98%20(2).md)
[[产品观察补充]] [外部](https://example.com/产品观察.md)
`[[产品观察]]`
```
[[产品观察]]
```
''',
    );
    expect(
      await nested.readAsString(),
      '[引用](../%E4%B8%AD%E6%96%87%E6%96%B0%E6%A0%87%E9%A2%98%20(2).md#正文)',
    );
    await workspace.close();
    workspace = await NoteWorkspace.open(
      localDirectory: local,
      vaultDirectory: vault,
    );
    expect(workspace.search('中文新标题').single.notePath, renamed.notePath);
    expect(workspace.search('原文保持').single.id, note.id);
    final unchanged = await workspace.renameNote(note.id, title: renamed.title);
    expect(unchanged.notePath, renamed.notePath);
    expect(workspace.notes, hasLength(1));
  });

  test(
    'duplicate file names reserve directories, case variants and symlinks',
    () async {
      await Directory('${vault.path}/设计.md').create();
      await File('${vault.path}/API.MD').writeAsString('既有文件');
      final outside = File('${temporary.path}/outside.md');
      await outside.writeAsString('不可覆盖');
      await Link('${vault.path}/链接.md').create(outside.path);
      expect(
        (await workspace.captureText(title: '设计', text: '目录重名')).title,
        '设计 (2)',
      );
      expect(
        (await workspace.captureText(title: 'api', text: '大小写重名')).title,
        'api (2)',
      );
      expect(
        (await workspace.captureText(title: '链接', text: '符号链接重名')).title,
        '链接 (2)',
      );
      expect(await outside.readAsString(), '不可覆盖');
    },
  );

  test('portable titles keep ordinary digits and ignore unusable semantic alternatives', () async {
    final literal = await workspace.captureText(
      title: 'x00 2026 方案',
      semanticTitleCandidates: ['', '..'],
      text: '用户输入的标题。',
    );
    expect(literal.title, 'x00 2026 方案');
    final portable = await workspace.captureText(
      title: 'CON.txt. ',
      text: '跨端可用的文件名。',
    );
    expect(portable.title, '笔记 CON.txt');
    expect(await File(portable.notePath).exists(), isTrue);
  });

  test('an interrupted link update resumes rename without losing either target or original', () async {
    final note = await workspace.captureText(title: '原标题', text: '完整来源。');
    final inbound = File('${vault.path}/关联入口.md');
    await inbound.writeAsString('[[原标题]]');
    await workspace.close();
    workspace = await NoteWorkspace.open(
      localDirectory: local,
      vaultStorage: _StopAfterLinkUpdateStorage(vault),
    );
    await expectLater(
      workspace.renameNote(note.id, title: '恢复后的标题'),
      throwsStateError,
    );
    expect(workspace.notes.single.status, NoteStatus.renamePending);
    expect(await File(note.notePath).exists(), isTrue);
    expect(await File('${vault.path}/恢复后的标题.md').exists(), isTrue);
    expect(await inbound.readAsString(), '[[恢复后的标题]]');
    await workspace.close();
    workspace = await NoteWorkspace.open(
      localDirectory: local,
      vaultDirectory: vault,
    );
    final restored = workspace.notes.single;
    expect(restored.title, '恢复后的标题');
    expect(restored.id, note.id);
    expect(restored.status, NoteStatus.localSaved);
    expect(await File(note.notePath).exists(), isFalse);
    expect(await File(restored.sourcePath).readAsString(), '完整来源。');
    expect(await inbound.readAsString(), '[[恢复后的标题]]');
  });

  test('simultaneous captures allocate distinct duplicate names', () async {
    final captured = await Future.wait([
      workspace.captureText(title: '共同标题', text: '第一份原文'),
      workspace.captureText(title: '共同标题', text: '第二份原文'),
      workspace.captureText(title: '共同标题', text: '第三份原文'),
    ]);
    expect(captured.map((note) => note.title), [
      '共同标题',
      '共同标题 (2)',
      '共同标题 (3)',
    ]);
    for (final note in captured) {
      expect(await File(note.sourcePath).readAsString(), note.text);
      expect(await File(note.notePath).readAsString(), contains(note.text));
    }
  });

  test('renaming maintains Markdown reference definitions and their optional titles', () async {
    final note = await workspace.captureText(title: '产品观察', text: '保持原始来源。');
    final index = File('${vault.path}/阅读索引.md');
    await index.writeAsString('''[阅读][plain] [定位][angle] [编码][encoded]
[plain]: 产品观察.md
[angle]: <产品观察.md#正文> "说明 产品观察"
[encoded]: %E4%BA%A7%E5%93%81%E8%A7%82%E5%AF%9F.md '说明'
[external]: https://example.com/产品观察.md
```
[example]: 产品观察.md
```
''');
    final folder = await Directory('${vault.path}/资料').create();
    final nested = File('${folder.path}/延伸阅读.md');
    await nested.writeAsString('  [relative]: ../产品观察.md (延伸阅读)');
    final renamed = await workspace.renameNote(note.id, title: '新标题');
    expect(renamed.status, NoteStatus.localSaved);
    expect(await index.readAsString(), '''[阅读][plain] [定位][angle] [编码][encoded]
[plain]: 新标题.md
[angle]: <新标题.md#正文> "说明 产品观察"
[encoded]: %E6%96%B0%E6%A0%87%E9%A2%98.md '说明'
[external]: https://example.com/产品观察.md
```
[example]: 产品观察.md
```
''');
    expect(await nested.readAsString(), '  [relative]: ../新标题.md (延伸阅读)');
    expect(await File(renamed.sourcePath).readAsString(), '保持原始来源。');
  });

  test('unavailable title lookup retains original and semantic request for retry after restart', () async {
    await File('${vault.path}/已有标题.md').writeAsString('现有笔记');
    await workspace.close();
    workspace = await NoteWorkspace.open(
      localDirectory: local,
      vaultStorage: _UnavailableTitleStorage(vault),
    );
    final retained = await workspace.captureText(
      title: '已有标题',
      semanticTitleCandidates: ['能区分含义的标题'],
      text: '离线保留完整原文。',
    );
    expect(retained.status, NoteStatus.exportFailed);
    expect(workspace.search('完整原文').single.text, '离线保留完整原文。');
    await workspace.close();
    workspace = await NoteWorkspace.open(
      localDirectory: local,
      vaultDirectory: vault,
    );
    final retried = await workspace.retryNoteExport(retained.id);
    expect(retried.title, '能区分含义的标题');
    expect(retried.status, NoteStatus.localSaved);
    expect(await File(retried.sourcePath).readAsString(), '离线保留完整原文。');
    expect(workspace.notes, hasLength(1));
    expect(await File('${vault.path}/已有标题.md').readAsString(), '现有笔记');
  });
}

/// Real vault I/O with a simulated process stop after a complete link update.
class _StopAfterLinkUpdateStorage extends DirectoryVaultStorage {
  _StopAfterLinkUpdateStorage(super.directory);

  @override
  Future<void> replaceText(
    String relativePath,
    String expectedText,
    String text,
    String operationId,
  ) async {
    await super.replaceText(relativePath, expectedText, text, operationId);
    throw StateError(
      'Simulated interruption after an inbound link was updated',
    );
  }
}

class _UnavailableTitleStorage extends DirectoryVaultStorage {
  _UnavailableTitleStorage(super.directory);

  @override
  Future<List<String>> listNotePaths() async =>
      throw const FileSystemException('Vault permission unavailable');
}
