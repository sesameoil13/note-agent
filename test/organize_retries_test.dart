import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/note_workspace.dart';
import 'package:sqlite3/sqlite3.dart';

import 'audio_queue_test.dart' show wave;
import 'support/ai_fixture.dart';

/// Captures keep going without help (#39): temporary failures retry about 1,
/// 5 and 30 minutes later, a rejected key or an empty balance pauses all
/// sending, and waiting captures go out oldest first.
void main() {
  late AiFixture f;
  setUp(() => f = AiFixture());
  tearDown(() => f.close());

  Future<void> later(NoteWorkspace w, Duration gap) async {
    f.now = f.now.add(gap);
    await w.sendWaitingNow();
  }

  test('a temporary failure is retried about 1, 5 and 30 minutes later, then shows 失败 and 重试 starts a new round', () async {
    f.modelStatuses.addAll([503, 500, 502, 504, 503]);
    await f.start(devices: 1);
    final w = f.workspaces.first;
    final note = await w.captureText(title: '想法', text: '服务暂时不可用时收集的想法。');

    await w.sendWaitingNow();
    expect(f.modelRequests, hasLength(1));
    expect(w.organizeStatus(note.id), OrganizeStatus.waiting);

    // Not before about a minute.
    await later(w, const Duration(seconds: 50));
    expect(f.modelRequests, hasLength(1));
    await later(w, const Duration(seconds: 10));
    expect(f.modelRequests, hasLength(2));

    await later(w, const Duration(minutes: 4));
    expect(f.modelRequests, hasLength(2));
    await later(w, const Duration(minutes: 1));
    expect(f.modelRequests, hasLength(3));

    await later(w, const Duration(minutes: 29));
    expect(f.modelRequests, hasLength(3));
    expect(w.organizeStatus(note.id), OrganizeStatus.waiting);
    await later(w, const Duration(minutes: 1));
    expect(f.modelRequests, hasLength(4));

    // After 3 retries: 失败, and no more automatic sends.
    expect(w.organizeStatus(note.id), OrganizeStatus.failed);
    await later(w, const Duration(hours: 2));
    expect(f.modelRequests, hasLength(4));

    // 重试 starts a new round of one send plus 3 retries.
    await w.recoverProcessingFailure(w.processingFailures.single.id);
    expect(f.modelRequests, hasLength(5));
    expect(w.organizeStatus(note.id), OrganizeStatus.waiting);
    await later(w, const Duration(minutes: 1));
    expect(f.modelRequests, hasLength(6));
    expect(w.organizeStatus(note.id), OrganizeStatus.organized);
  });

  for (final status in [401, 403]) {
    test('a rejected key ($status) pauses all sending until the key is reconnected, also after reopening', () async {
      f.modelStatuses.add(status);
      await f.start(devices: 1);
      final w = f.workspaces.first;
      final first = await w.captureText(title: '先', text: '先收集的想法。');
      final second = await w.captureText(title: '后', text: '后收集的想法。');

      await w.sendWaitingNow();
      expect(f.modelRequests, hasLength(1));
      expect(w.sendingPause, OrganizePause.key);
      expect(w.sendingPause!.message, contains('重新连接'));
      expect(w.organizeStatus(first.id), OrganizeStatus.waiting);
      expect(w.organizeStatus(second.id), OrganizeStatus.waiting);

      // Never retried automatically, however long it waits.
      await later(w, const Duration(hours: 3));
      await f.reopen(0);
      final reopened = f.workspaces.first;
      await later(reopened, const Duration(hours: 3));
      expect(f.modelRequests, hasLength(1));
      expect(reopened.sendingPause, OrganizePause.key);

      await reopened.connection.connectAi('sk-ai-fixture-only-key');
      await reopened.sendWaitingNow();

      expect(reopened.sendingPause, isNull);
      expect(reopened.organizeStatus(first.id), OrganizeStatus.organized);
      expect(reopened.organizeStatus(second.id), OrganizeStatus.organized);
      expect(f.modelRequests, hasLength(3));
    });
  }

  test('a key reconnected while the paused vault was closed resumes sending when it reopens', () async {
    f.modelStatuses.add(401);
    await f.start(devices: 1);
    final w = f.workspaces.first;
    final note = await w.captureText(title: '想法', text: 'Key 被拒时收集的想法。');
    await w.sendWaitingNow();
    expect(w.sendingPause, OrganizePause.key);

    await f.reopen(0);
    final reopened = f.workspaces.first;
    // Connected before the first send after reopening, e.g. from another
    // vault the app had open meanwhile.
    await reopened.connection.connectAi('sk-ai-fixture-only-key');
    await reopened.sendWaitingNow();

    expect(reopened.sendingPause, isNull);
    expect(reopened.organizeStatus(note.id), OrganizeStatus.organized);
  });

  test('an empty balance (402) pauses all sending until the next try after a top-up', () async {
    f.modelStatuses.add(402);
    await f.start(devices: 1);
    final w = f.workspaces.first;
    final note = await w.captureText(title: '想法', text: '余额不足时收集的想法。');

    await w.sendWaitingNow();
    expect(w.sendingPause, OrganizePause.balance);
    expect(w.sendingPause!.message, contains('充值'));
    expect(w.organizeStatus(note.id), OrganizeStatus.waiting);
    await later(w, const Duration(hours: 3));
    expect(f.modelRequests, hasLength(1));

    await w.resumeSending();

    expect(w.sendingPause, isNull);
    expect(w.organizeStatus(note.id), OrganizeStatus.organized);
    expect(f.modelRequests, hasLength(2));
  });

  String sentText(Map<String, dynamic> request) =>
      (jsonDecode((request['messages'] as List).last['content'] as String)
              as Map)['text']
          as String;

  test('captures made with no network are sent oldest first once it returns', () async {
    await f.start(devices: 1);
    final w = f.workspaces.first;
    f.offline = true;
    final first = await w.captureText(title: '先', text: '离线时先收集的。');
    await w.sendWaitingNow();
    final second = await w.captureText(title: '后', text: '离线时后收集的。');
    await w.sendWaitingNow();
    expect(w.organizeStatus(first.id), OrganizeStatus.waiting);
    expect(w.organizeStatus(second.id), OrganizeStatus.waiting);

    f.offline = false;
    await later(w, const Duration(minutes: 1));

    expect(f.modelRequests.map(sentText), ['离线时先收集的。', '离线时后收集的。']);
    expect(w.organizeStatus(first.id), OrganizeStatus.organized);
    expect(w.organizeStatus(second.id), OrganizeStatus.organized);
  });

  test('captures made before a key is connected are sent oldest first once it is', () async {
    await f.start(devices: 1);
    final w = f.workspaces.first;
    await w.connection.disconnectAi();
    final first = await w.captureText(title: '先', text: '连接前先收集的。');
    await w.sendWaitingNow();
    final second = await w.captureText(title: '后', text: '连接前后收集的。');
    await w.sendWaitingNow();
    expect(f.modelRequests, isEmpty);
    expect(w.organizeStatus(first.id), OrganizeStatus.waiting);

    await w.connection.connectAi('sk-ai-fixture-only-key');
    await w.sendWaitingNow();

    expect(f.modelRequests.map(sentText), ['连接前先收集的。', '连接前后收集的。']);
    expect(w.organizeStatus(second.id), OrganizeStatus.organized);
  });

  test('a send interrupted by closing the app is organized on reopen without a second request', () async {
    await f.start(devices: 1);
    final note = await f.workspaces.first.captureText(
      title: '想法',
      text: '关闭 App 时正在发送的想法。',
    );
    Future<void>? closing;
    // The app closes while the request is out; the reply still arrives.
    f.beforeReply = () async {
      closing ??= f.reopen(0);
    };

    await f.workspaces.first.sendWaitingNow();
    await closing;
    final reopened = f.workspaces.first;
    await reopened.sendWaitingNow();
    await f.reopen(0);
    await f.workspaces.first.sendWaitingNow();

    expect(f.modelRequests, hasLength(1));
    expect(
      f.workspaces.first.organizeStatus(note.id),
      OrganizeStatus.organized,
    );
    expect(f.workspaces.first.notes.single.text, '整理后的普通想法。');
  });

  test('an app killed while sending again and again counts each restart as a try, then shows 失败', () async {
    await f.start(devices: 1);
    final note = await f.workspaces.first.captureText(
      title: '想法',
      text: '发送时 App 一直被杀掉的想法。',
    );
    // Stands in for the app being killed while the request was out.
    void killedWhileSending(Directory local) {
      final db = sqlite3.open('${local.path}/workspace.sqlite3');
      db.execute("UPDATE text_jobs SET status='sending'");
      db.close();
    }

    for (var restart = 1; restart <= 3; restart++) {
      await f.reopen(0, whileClosed: killedWhileSending);
      expect(
        f.workspaces.first.organizeStatus(note.id),
        OrganizeStatus.waiting,
      );
    }
    await f.reopen(0, whileClosed: killedWhileSending);
    final w = f.workspaces.first;
    expect(w.organizeStatus(note.id), OrganizeStatus.failed);
    await later(w, const Duration(hours: 2));
    expect(f.modelRequests, isEmpty);
  });

  test('audio retries and pauses the same way as text', () async {
    f.audioStatuses.addAll([503, 402]);
    await f.start(devices: 1);
    final w = f.workspaces.first;
    final source = await w.importAudio(
      original: await File('${f.root.path}/memo.wav')
          .writeAsBytes(wave(seconds: 4)),
      submissionId: 'retry-audio',
    );

    await w.sendWaitingNow();
    expect(w.organizeStatus(source.outputNoteId), OrganizeStatus.waiting);
    await later(w, const Duration(minutes: 1));
    expect(f.audioRequests, hasLength(2));
    expect(w.sendingPause, OrganizePause.balance);

    await later(w, const Duration(hours: 1));
    expect(f.audioRequests, hasLength(2));
    await w.resumeSending();

    expect(f.audioRequests, hasLength(3));
    expect(f.modelRequests, hasLength(1));
    expect(w.organizeStatus(source.outputNoteId), OrganizeStatus.organized);
  });
}
