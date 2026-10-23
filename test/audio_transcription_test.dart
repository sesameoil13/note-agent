import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/note_workspace.dart';

import 'support/budget_fixture.dart';
import 'audio_queue_test.dart' show wave;

void main() {
  for (final changedAfterPreparation in [false, true]) {
    test(
      'deferred audio organization freezes the complete note and protects later edits ($changedAfterPreparation)',
      () async {
        final f = BudgetFixture();
        await f.start();
        addTearDown(f.close);
        f.omitAudioCost = true;
        final w = f.workspaces.first;
        final source = await w.importAudio(
          original: await File('${f.root.path}/synthetic.wav')
              .writeAsBytes(wave()),
          submissionId: 'audio-note-snapshot',
        );
        await w.prepareAudioProcessing(source.id);
        await w.confirmAudioProcessing(source.id);
        expect(w.audioJobs.single.status, AudioJobStatus.paused);
        expect(f.modelRequests, isEmpty);
        final note = w.notes.single;
        final retained = (await File(note.notePath).readAsString())
            .replaceFirst('暂无关联', '- [[手工关联]]')
            .replaceFirst('\n记录：', '\n[手工来源](manual.txt)\n\n记录：');
        await File(note.notePath).writeAsString(retained);
        f.generationAvailable = true;
        f.generationCost = 0.00001;
        await w.reconcileAudioProcessing(source.id);
        await w.prepareAudioOrganization(source.id);
        expect(w.audioJobs.single.status, AudioJobStatus.prepared);
        final external = '$retained\n准备后在外部补充。\n';
        if (changedAfterPreparation) {
          f.beforeReply = () async {
            await File(note.notePath).writeAsString(external);
          };
        }
        await w.confirmAudioProcessing(source.id);
        expect(f.audioRequests, 1);
        expect(f.modelRequests, hasLength(1));
        expect(
          w.textJobs.single.status,
          changedAfterPreparation
              ? TextProcessingStatus.review
              : TextProcessingStatus.completed,
        );
        final saved = w.notes.single;
        final md = await File(saved.notePath).readAsString();
        if (changedAfterPreparation) {
          expect(md, external);
          expect(saved.text, f.transcript);
        } else {
          expect(saved.text, '整理后的普通想法。');
          expect(md, contains('[[手工关联]]'));
          expect(md, contains('[手工来源](manual.txt)'));
          expect(md, contains('synthetic.wav'));
        }
        expect(saved.originalText, f.transcript);
        expect(await File(saved.sourcePath).readAsString(), f.transcript);
        expect(await File(source.originalPath).readAsBytes(), wave());
        await f.reopen(0);
        expect(
          await File(f.workspaces.first.notes.single.notePath).readAsString(),
          md,
        );
        expect(f.audioRequests, 1);
        expect(f.modelRequests, hasLength(1));
      },
    );
  }
  test('one consent transcribes then organizes with both templates and durable full sources', () async {
    final f = BudgetFixture();
    await f.start();
    addTearDown(f.close);
    final w = f.workspaces.first;
    final original = await File('${f.root.path}/synthetic.wav')
        .writeAsBytes(wave());
    final source = await w.importAudio(
      original: original,
      submissionId: 'synthetic-one',
    );
    await w.resumePendingAudioProcessing();
    expect(f.audioRequests, 0);
    expect(f.modelRequests, isEmpty);
    final prepared = await w.prepareAudioProcessing(source.id);
    expect(prepared.estimatedCnyMicros, greaterThan(0));
    expect(prepared.description, contains('不保证远端价格封顶'));
    expect(f.audioRequests, 0);
    f.modelResult = {
      'kind': 'todo',
      'title': '整理会议记录',
      'body': '整理会议记录。',
      'actions': [
        {
          'text': '整理会议记录',
          'reason': 'none',
          'timeExpression': '明天下午两点',
          'timeStatus': 'explicit',
        },
      ],
    };
    await w.confirmAudioProcessing(source.id);
    expect(f.audioRequests, 1);
    expect(f.modelRequests, hasLength(1));
    expect(f.lastAudioRequest!['model'], 'openai/whisper-large-v3-turbo');
    expect(f.lastAudioRequest!['input_audio']['format'], 'wav');
    expect(f.lastAudioRequest!.containsKey('provider'), false);
    final note = w.notes.single;
    expect(note.kind, NoteKind.todo);
    final reminder = w.reminders.single;
    expect(reminder.noteId, note.id);
    expect(reminder.actionId, note.actions.single.id);
    expect(reminder.explicitTime, true);
    final collected = note.createdAt.toLocal();
    expect(
      reminder.time,
      DateTime(collected.year, collected.month, collected.day + 1, 14),
    );
    expect(reminder.status, ReminderStatus.blocked);
    expect(note.originalText, f.transcript);
    expect(await File(note.sourcePath).readAsString(), f.transcript);
    final md = await File(note.notePath).readAsString();
    expect(md, contains('## 待办'));
    expect(md, contains('## 摘要'));
    expect(md, contains('[完整转写]'));
    expect(md, contains('synthetic.wav'));
    expect(await File(source.originalPath).readAsBytes(), wave());
    await f.reopen(0);
    await f.workspaces.first.resumePendingAudioProcessing();
    expect(f.audioRequests, 1);
    expect(f.modelRequests, hasLength(1));
    expect(f.workspaces.first.notes.single.originalText, f.transcript);
    expect(f.workspaces.first.reminders.single.id, reminder.id);
    await f.workspaces.first.reconcileReminders();
    expect(f.workspaces.first.reminders.single.id, reminder.id);
  });
  test('missing STT receipt preserves full transcript and unknown hold, without organizing or replay', () async {
    final f = BudgetFixture();
    await f.start();
    addTearDown(f.close);
    f.omitAudioCost = true;
    f.omitAudioId = true;
    final w = f.workspaces.first;
    final source = await w.importAudio(
      original: await File('${f.root.path}/synthetic.wav').writeAsBytes(wave()),
      submissionId: 'missing-receipt',
    );
    await w.prepareAudioProcessing(source.id);
    await w.confirmAudioProcessing(source.id);
    expect(w.audioJobs.single.status, AudioJobStatus.paused);
    expect(w.notes.single.originalText, f.transcript);
    expect(w.budget.unknownCnyMicros, greaterThan(0));
    expect(f.modelRequests, isEmpty);
    await f.reopen(0);
    await f.workspaces.first.confirmAudioProcessing(source.id);
    await f.workspaces.first.reconcileAudioProcessing(source.id);
    expect(f.audioRequests, 1);
    expect(f.modelRequests, isEmpty);
    expect(f.workspaces.first.budget.unknownCnyMicros, greaterThan(0));
  });
  test('oversized complete transcript remains findable and is never silently truncated or sent', () async {
    final f = BudgetFixture();
    await f.start();
    addTearDown(f.close);
    f.transcript = List.filled(10000, '记录').join();
    final w = f.workspaces.first;
    final source = await w.importAudio(
      original: await File('${f.root.path}/synthetic.wav').writeAsBytes(wave()),
      submissionId: 'large-transcript',
    );
    await w.prepareAudioProcessing(source.id);
    await w.confirmAudioProcessing(source.id);
    expect(w.audioJobs.single.status, AudioJobStatus.paused);
    expect(w.audioJobs.single.message, contains('超过'));
    expect(w.notes.single.originalText, f.transcript);
    expect(await File(w.notes.single.sourcePath).readAsString(), f.transcript);
    expect(f.modelRequests, isEmpty);
    expect(w.budget.reservedCnyMicros, 0);
    await w.prepareAudioOrganization(source.id);
    expect(w.audioJobs.single.status, AudioJobStatus.paused);
    expect(f.modelRequests, isEmpty);
    expect(w.budget.reservedCnyMicros, 0);
  });
  test('changed private original after prepare rejects upload and releases only unsent funds', () async {
    final f = BudgetFixture();
    await f.start();
    addTearDown(f.close);
    final w = f.workspaces.first;
    final source = await w.importAudio(
      original: await File('${f.root.path}/synthetic.wav').writeAsBytes(wave()),
      submissionId: 'changed-audio',
    );
    await w.prepareAudioProcessing(source.id);
    final bytes = wave();
    bytes[50] = bytes[50] ^ 255;
    await File(source.originalPath).writeAsBytes(bytes);
    await w.confirmAudioProcessing(source.id);
    expect(w.audioJobs.single.status, AudioJobStatus.paused);
    expect(f.audioRequests, 0);
    expect(f.modelRequests, isEmpty);
    expect(w.budget.reservedCnyMicros, 0);
  });
  test(
    'concurrent confirms share one dispatch and cancellation never uploads',
    () async {
      final f = BudgetFixture();
      await f.start();
      addTearDown(f.close);
      final w = f.workspaces.first;
      final file = await File('${f.root.path}/synthetic.wav')
          .writeAsBytes(wave());
      final source = await w.importAudio(
        original: file,
        submissionId: 'concurrent-audio',
      );
      await w.prepareAudioProcessing(source.id);
      await Future.wait([
        w.confirmAudioProcessing(source.id),
        w.confirmAudioProcessing(source.id),
      ]);
      expect(f.audioRequests, 1);
      expect(f.modelRequests, hasLength(1));
      final next = await w.importAudio(
        original: file,
        submissionId: 'cancelled-audio',
      );
      await w.prepareAudioProcessing(next.id);
      await w.cancelAudioProcessing(next.id);
      await w.confirmAudioProcessing(next.id);
      expect(f.audioRequests, 1);
      expect(f.modelRequests, hasLength(1));
      expect(w.budget.reservedCnyMicros, 0);
    },
  );
  test('manual organization retry reuses durable transcript without a second audio upload', () async {
    final f = BudgetFixture();
    await f.start();
    addTearDown(f.close);
    f.modelStatuses.add(503);
    final w = f.workspaces.first;
    final source = await w.importAudio(
      original: await File('${f.root.path}/synthetic.wav').writeAsBytes(wave()),
      submissionId: 'retry-stage',
    );
    await w.prepareAudioProcessing(source.id);
    await w.confirmAudioProcessing(source.id);
    expect(w.audioJobs.single.status, AudioJobStatus.paused);
    expect(f.audioRequests, 1);
    expect(f.modelRequests, hasLength(1));
    final previousHold = w.budget.unknownCnyMicros;
    expect(previousHold, greaterThan(0));
    await w.prepareAudioOrganization(source.id);
    expect(f.audioRequests, 1);
    expect(f.modelRequests, hasLength(1));
    await w.confirmAudioProcessing(source.id);
    expect(f.audioRequests, 1);
    expect(f.modelRequests, hasLength(2));
    expect(w.notes, hasLength(1));
    expect(w.notes.single.originalText, f.transcript);
    expect(w.budget.unknownCnyMicros, previousHold);
  });
  test('explicit upload retry gets new holds while a failed upload remains unknown across restart', () async {
    final f = BudgetFixture();
    await f.start();
    addTearDown(f.close);
    f.audioStatus = 503;
    final w = f.workspaces.first;
    final source = await w.importAudio(
      original: await File('${f.root.path}/synthetic.wav').writeAsBytes(wave()),
      submissionId: 'upload-retry',
    );
    await w.prepareAudioProcessing(source.id);
    await w.confirmAudioProcessing(source.id);
    expect(f.audioRequests, 1);
    expect(f.modelRequests, isEmpty);
    final unknown = w.budget.unknownCnyMicros;
    expect(unknown, greaterThan(0));
    await f.reopen(0);
    final reopened = f.workspaces.first;
    await reopened.resumePendingAudioProcessing();
    expect(f.audioRequests, 1);
    f.audioStatus = 200;
    await reopened.prepareAudioRetry(source.id);
    expect(reopened.audioJobs.single.status, AudioJobStatus.prepared);
    expect(f.audioRequests, 1);
    expect(reopened.budget.unknownCnyMicros, unknown);
    await reopened.confirmAudioProcessing(source.id);
    expect(f.audioRequests, 2);
    expect(f.modelRequests, hasLength(1));
    expect(reopened.budget.unknownCnyMicros, unknown);
    expect(reopened.notes, hasLength(1));
  });
  for (final deferred in [false, true]) {
    test(
      'recording transcript sends frozen semantic candidates and applies multiple links with pending new topic (deferred: $deferred)',
      () async {
        final f = BudgetFixture();
        await f.start();
        addTearDown(f.close);
        final w = f.workspaces.first;
        f.omitAudioCost = deferred;
        final research = await w.captureText(
          title: '用户访谈',
          text: '访谈反映新手理解产品的障碍。',
        );
        final design = await w.captureText(
          title: '体验设计',
          text: '首次使用体验需要降低认知负担。',
        );
        f.transcript = '受访者第一次打开工具，不知道下一步该点哪里。';
        f.modelResult = {
          'manifestVersion': 3,
          'kind': 'ordinary',
          'title': '首次使用观察',
          'body': '受访者初次打开工具时不知道下一步操作。',
          'actions': [],
          'associations': [
            {'noteId': research.id, 'reason': '同为访谈中观察到的使用障碍。'},
            {'noteId': design.id, 'reason': '为首次使用体验提供设计依据。'},
          ],
          'newTopics': [
            {'title': '引导流程', 'reason': '汇集初次使用体验线索。'},
          ],
        };
        final source = await w.importAudio(
          original: await File('${f.root.path}/synthetic.wav')
              .writeAsBytes(wave()),
          submissionId: 'audio-semantic',
        );
        await w.prepareAudioProcessing(source.id);
        await w.confirmAudioProcessing(source.id);
        if (deferred) {
          expect(f.modelRequests, isEmpty);
          f.generationAvailable = true;
          f.generationCost = 0.00001;
          await w.reconcileAudioProcessing(source.id);
          await w.prepareAudioOrganization(source.id);
          expect(f.audioRequests, 1);
          expect(f.modelRequests, isEmpty);
          await w.confirmAudioProcessing(source.id);
        }
        final note = w.notes.firstWhere((n) => n.id == source.outputNoteId);
        expect(note.associations.map((a) => a.targetNoteId), [
          research.id,
          design.id,
        ]);
        expect(note.originalText, f.transcript);
        expect(w.pendingTopicSuggestions.single.title, '引导流程');
        expect(w.notes, hasLength(3));
        final request = f.modelRequests.single;
        final input = jsonDecode(
          (request['messages'] as List).last['content'] as String,
        ) as Map;
        expect(
          (input['associationCandidates'] as List).map((c) => c['noteId']),
          containsAll([research.id, design.id]),
        );
        expect(
          utf8.encode(jsonEncode(request)).length,
          lessThanOrEqualTo(20000),
        );
        final md = await File(note.notePath).readAsString();
        expect(md, contains('[[用户访谈]]'));
        expect(md, contains('[[体验设计]]'));
        expect(md, isNot(contains('[[引导流程]]')));
        await f.reopen(0);
        expect(
          f.workspaces.first.notes
              .firstWhere((n) => n.id == note.id)
              .associations,
          hasLength(2),
        );
        expect(
          f.workspaces.first.pendingTopicSuggestions.single.noteId,
          note.id,
        );
        expect(f.audioRequests, 1);
        expect(f.modelRequests, hasLength(1));
      },
    );
  }
  for (final mode in ['initial', 'deferred', 'retry']) {
    test(
      'optional association context yields space to the complete Mandarin transcript within the consent bound ($mode)',
      () async {
        final f = BudgetFixture();
        f.omitAudioCost = mode == 'deferred';
        if (mode == 'retry') f.modelStatuses.add(503);
        await f.start();
        addTearDown(f.close);
        final w = f.workspaces.first;
        for (var i = 0; i < 12; i++) {
          await w.captureText(
            title: '体验设计$i',
            text: List.filled(200, '用户访谈与首次使用体验。').join(),
          );
        }
        f.transcript = List.filled(250, '用户访谈记录首次使用体验。').join();
        final source = await w.importAudio(
          original: await File('${f.root.path}/synthetic.wav')
              .writeAsBytes(wave()),
          submissionId: 'bounded-audio-context',
        );
        f.beforeReply = () async {
          final request = f.modelRequests.last;
          final input = jsonDecode(
            (request['messages'] as List).last['content'] as String,
          ) as Map;
          final sent = (input['associationCandidates'] as List)
              .map((c) => c['noteId'])
              .toSet();
          final omitted = w.notes.firstWhere(
            (n) => n.id != source.outputNoteId && !sent.contains(n.id),
          );
          f.modelResult = {
            'manifestVersion': 3,
            'kind': 'ordinary',
            'title': '错误关联',
            'body': '此结果不得覆盖原文。',
            'actions': [],
            'associations': [
              {'noteId': omitted.id, 'reason': '未发送候选不得成为链接。'},
            ],
            'newTopics': [],
          };
        };
        await w.prepareAudioProcessing(source.id);
        await w.confirmAudioProcessing(source.id);
        if (mode == 'deferred') {
          expect(f.modelRequests, isEmpty);
          f.generationAvailable = true;
          f.generationCost = 0.00001;
          await w.reconcileAudioProcessing(source.id);
        }
        if (mode != 'initial') {
          await w.prepareAudioOrganization(source.id);
          expect(w.audioJobs.single.status, AudioJobStatus.prepared);
          await w.confirmAudioProcessing(source.id);
        }
        expect(f.modelRequests, hasLength(mode == 'retry' ? 2 : 1));
        for (final sent in f.modelRequests) {
          expect(
            utf8.encode(jsonEncode(sent)).length,
            lessThanOrEqualTo(20000),
          );
          final sentInput = jsonDecode(
            (sent['messages'] as List).last['content'] as String,
          ) as Map;
          expect(sentInput['text'], f.transcript);
        }
        final request = f.modelRequests.last;
        expect(
          utf8.encode(jsonEncode(request)).length,
          lessThanOrEqualTo(20000),
        );
        final input = jsonDecode(
          (request['messages'] as List).last['content'] as String,
        ) as Map;
        expect(input['text'], f.transcript);
        expect((input['associationCandidates'] as List).length, lessThan(12));
        expect((input['associationCandidates'] as List).length, greaterThan(0));
        final note = w.notes.firstWhere((n) => n.id == source.outputNoteId);
        expect(note.originalText, f.transcript);
        expect(note.associations, isEmpty);
        expect(w.textJobs.single.status, TextProcessingStatus.review);
        expect(note.text, f.transcript);
        expect(await File(note.sourcePath).readAsString(), f.transcript);
        expect(f.audioRequests, 1);
      },
    );
  }
}
