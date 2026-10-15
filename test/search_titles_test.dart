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

  test('find collected original text by title or keywords after restart', () async {
    await workspace.captureText(title: '设计观察', text: '保留完整原文。\n排版使用八点网格。');
    await workspace.captureText(title: '客户反馈', text: '标题之外的检索关键词：离线。');
    await workspace.captureText(title: 'API 记录', text: 'Case insensitive retrieval.');
    await workspace.close();
    workspace = await NoteWorkspace.open(localDirectory: local, vaultDirectory: vault);

    expect(workspace.search('  设计  ').single.title, '设计观察');
    final found = workspace.search('离线').single;
    expect(found.text, '标题之外的检索关键词：离线。');
    expect(await File(found.sourcePath).readAsString(), found.text);
    expect(await File(found.notePath).readAsString(), contains(found.text));
    expect(workspace.search('case').single.title, 'API 记录');
    expect(workspace.search('不存在'), isEmpty);
    expect(workspace.search('').map((note) => note.title), ['API 记录', '客户反馈', '设计观察']);
  });

  test('try supplied semantic titles before numbering duplicates without blocking', () async {
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
    expect(duplicate.title, '会议记录（2）');
    expect(duplicate.titleCollision, isTrue);
    expect(duplicate.status, NoteStatus.localSaved);
    final next = await workspace.captureText(title: '会议记录', text: '第三份原文。');
    expect(next.title, '会议记录（3）');
    expect(await existing.readAsString(), '用户已有的会议记录');
    await workspace.close();
    workspace = await NoteWorkspace.open(localDirectory: local, vaultDirectory: vault);
    expect(workspace.search('另一份').single.titleCollision, isTrue);
    expect(workspace.notes, hasLength(3));
  });
}
