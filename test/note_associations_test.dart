import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/note_workspace.dart';

import 'support/budget_fixture.dart';

void main() {
  test('semantic model links multiple existing notes and defers a new topic without blocking the original save', () async {
    final f = BudgetFixture();
    await f.start();
    addTearDown(f.close);
    final w = f.workspaces.first;
    final research = await w.captureText(
      title: '用户访谈',
      text: '访谈反映了新手理解产品的障碍。',
    );
    final design = await w.captureText(title: '体验设计', text: '首次使用体验需要降低认知负担。');
    final source = await w.captureText(
      title: '观察记录',
      text: '受访者第一次打开工具，不知道下一步该点哪里。',
    );
    f.modelResult = {
      'manifestVersion': 3,
      'kind': 'ordinary',
      'title': '首次使用观察',
      'body': '受访者第一次打开工具时，不知道下一步如何操作。',
      'actions': [],
      'associations': [
        {'noteId': research.id, 'reason': '同为研究中观察到的使用障碍。'},
        {'noteId': design.id, 'reason': '可为首次使用流程的设计提供依据。'},
      ],
      'newTopics': [
        {'title': '引导流程', 'reason': '集中记录后续首次使用体验的改进线索。'},
      ],
    };
    await w.processTextNote(source.id);
    final note = w.notes.firstWhere((n) => n.id == source.id);
    expect(note.associations.map((a) => a.targetNoteId), [
      research.id,
      design.id,
    ]);
    expect(note.associations.last.reason, '可为首次使用流程的设计提供依据。');
    expect(note.status, NoteStatus.localSaved);
    expect(w.notes.length, 3);
    expect(w.pendingTopicSuggestions.single.title, '引导流程');
    final markdown = await File(note.notePath).readAsString();
    expect(markdown, contains('[[用户访谈]]'));
    expect(markdown, contains('[[体验设计]]'));
    expect(markdown, isNot(contains('[[引导流程]]')));
    expect(await File(note.sourcePath).readAsString(), source.text);
    final input = jsonDecode(
      f.modelRequests.single['messages'].last['content'] as String,
    ) as Map;
    expect(
      (input['associationCandidates'] as List).map((c) => c['noteId']),
      containsAll([research.id, design.id]),
    );
    await f.reopen(0);
    expect(f.workspaces.first.pendingTopicSuggestions.single.noteId, source.id);
    expect(
      f.workspaces.first.notes
          .firstWhere((n) => n.id == source.id)
          .associations
          .length,
      2,
    );
  });
  test('user approves or ignores topics and removes a wrong relation after target rename without a new model call', () async {
    final f = BudgetFixture();
    await f.start();
    addTearDown(f.close);
    final w = f.workspaces.first;
    final target = await w.captureText(title: '旧主题', text: '体验记录');
    final source = await w.captureText(title: '待处理', text: '观察首次使用体验。');
    f.modelResult = {
      'manifestVersion': 3,
      'kind': 'ordinary',
      'title': '观察',
      'body': '观察首次使用体验。',
      'actions': [],
      'associations': [
        {'noteId': target.id, 'reason': '共同讨论使用体验。'},
      ],
      'newTopics': [
        {'title': '引导设计', 'reason': '集中记录首次使用问题。'},
        {'title': '问题清单', 'reason': '待研究的问题。'},
      ],
    };
    await w.processTextNote(source.id);
    await w.renameNote(target.id, title: '体验设计');
    final suggestion = w.pendingTopicSuggestions.first;
    await w.confirmTopicSuggestion(suggestion.id);
    await w.confirmTopicSuggestion(suggestion.id);
    await w.ignoreTopicSuggestion(w.pendingTopicSuggestions.single.id);
    expect(w.notes.where((n) => n.title == '引导设计').length, 1);
    expect(w.pendingConfirmationNotes, isEmpty);
    expect(w.pendingTopicSuggestions, isEmpty);
    final note = w.notes.firstWhere((n) => n.id == source.id);
    expect(note.associations.map((a) => a.title), ['体验设计', '引导设计']);
    expect(await File(note.notePath).readAsString(), contains('[[体验设计]]'));
    await w.removeAssociation(source.id, target.id);
    expect(
      await File(note.notePath).readAsString(),
      isNot(contains('[[体验设计]]')),
    );
    expect(
      w.notes.firstWhere((n) => n.id == source.id).associations.single.title,
      '引导设计',
    );
    expect(f.modelRequests.length, 1);
    await f.reopen(0);
    expect(f.workspaces.first.pendingTopicSuggestions, isEmpty);
    expect(
      f.workspaces.first.notes
          .firstWhere((n) => n.id == source.id)
          .associations
          .single
          .title,
      '引导设计',
    );
  });

  test(
    'unknown identities cannot become links or overwrite the saved original',
    () async {
      final f = BudgetFixture();
      await f.start();
      addTearDown(f.close);
      final w = f.workspaces.first;
      final n = await w.captureText(title: '原记录', text: '雨后树叶呈现绿色。');
      f.modelResult = {
        'manifestVersion': 3,
        'kind': 'ordinary',
        'title': '雨后',
        'body': '整理内容',
        'actions': [],
        'associations': [
          {'noteId': 'invented-note', 'reason': '未知身份'},
        ],
        'newTopics': [],
      };
      await w.processTextNote(n.id);
      expect(w.notes.single.text, n.text);
      expect(w.notes.single.associations, isEmpty);
      expect(w.pendingTopicSuggestions, isEmpty);
      expect(await File(n.sourcePath).readAsString(), n.text);
      expect(w.textJobs.single.status, TextProcessingStatus.review);
    },
  );

  test('a failed approved topic publication recovers once and external body edits remain protected', () async {
    final f = BudgetFixture();
    await f.start();
    addTearDown(f.close);
    var w = f.workspaces.first;
    final n = await w.captureText(title: '观察', text: '首次使用时迷路。');
    f.modelResult = {
      'manifestVersion': 3,
      'kind': 'ordinary',
      'title': '首次使用',
      'body': '首次使用时迷路。',
      'actions': [],
      'associations': [],
      'newTopics': [
        {'title': '导航设计', 'reason': '收集导航问题。'},
      ],
    };
    await w.processTextNote(n.id);
    final suggestion = w.pendingTopicSuggestions.single.id;
    final storage = _FailAssociationStorage(
      (w.vaultStorage as DirectoryVaultStorage).directory,
    );
    await f.reopen(0, vaultStorage: storage);
    w = f.workspaces.first;
    await expectLater(
      w.confirmTopicSuggestion(suggestion),
      throwsA(isA<FileSystemException>()),
    );
    expect(
      w.notes.firstWhere((v) => v.id == n.id).associationSavePending,
      isTrue,
    );
    expect(w.notes.where((v) => v.title == '导航设计').length, 1);
    await expectLater(w.renameNote(n.id, title: '暂停改名'), throwsStateError);
    await f.reopen(0);
    w = f.workspaces.first;
    expect(w.pendingTopicSuggestions, isEmpty);
    expect(w.notes.where((v) => v.title == '导航设计').length, 1);
    final note = w.notes.firstWhere((v) => v.id == n.id);
    expect(note.associations.single.title, '导航设计');
    final external = (await File(
      note.notePath,
    ).readAsString()).replaceFirst('首次使用时迷路。', '我在 Obsidian 修改的正文。');
    await File(note.notePath).writeAsString(external);
    await expectLater(
      w.removeAssociation(n.id, note.associations.single.targetNoteId),
      throwsA(isA<FileSystemException>()),
    );
    expect(await File(note.notePath).readAsString(), external);
    expect(w.notes.firstWhere((v) => v.id == n.id).associations.length, 1);
    expect(f.modelRequests.length, 1);
  });
  test('an unavailable vault during automatic linking leaves the workspace usable and recovers without resending', () async {
    final f = BudgetFixture();
    await f.start();
    addTearDown(f.close);
    var w = f.workspaces.first;
    final n = await w.captureText(title: '原记录', text: '研究新手的体验问题。');
    final target = await w.captureText(title: '研究', text: '用户体验研究');
    final storage = _FailAssociationStorage(
      (w.vaultStorage as DirectoryVaultStorage).directory,
    );
    await f.reopen(0, vaultStorage: storage);
    w = f.workspaces.first;
    f.modelResult = {
      'manifestVersion': 3,
      'kind': 'ordinary',
      'title': '新手体验',
      'body': '研究新手的体验问题。',
      'actions': [],
      'associations': [
        {'noteId': target.id, 'reason': '同为体验研究。'},
      ],
      'newTopics': [],
    };
    await w.processTextNote(n.id);
    expect(
      w.notes.firstWhere((v) => v.id == n.id).associationSavePending,
      isTrue,
    );
    await f.reopen(0, vaultStorage: storage);
    w = f.workspaces.first;
    expect(w.notes.length, 2);
    expect(
      w.notes.firstWhere((v) => v.id == n.id).associationSavePending,
      isTrue,
    );
    storage.blocked = false;
    final retry = w.retryAssociationSave(n.id);
    await w.close();
    await retry;
    await f.reopen(0);
    w = f.workspaces.first;
    expect(
      w.notes.firstWhere((v) => v.id == n.id).associations.single.targetNoteId,
      target.id,
    );
    expect(w.textJobs.single.status, TextProcessingStatus.completed);
    expect(f.modelRequests.length, 1);
  });
}

class _FailAssociationStorage extends DirectoryVaultStorage {
  _FailAssociationStorage(super.directory);
  bool blocked = true;
  @override
  Future<void> replaceText(
    String path,
    String before,
    String after,
    String operationId,
  ) async {
    if (blocked && operationId.startsWith('association-')) {
      throw const FileSystemException(
        'synthetic interrupted association write',
      );
    }
    await super.replaceText(path, before, after, operationId);
  }
}
