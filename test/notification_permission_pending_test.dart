import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/note_workspace.dart';

void main() {
  for (final inspectionOffset in [1, 2]) {
    for (final lateError in [false, true]) {
      test(
        'an earlier inspection yields when permission starts and ignores its late result ($inspectionOffset, error: $lateError)',
        () async {
          final root = await Directory.systemTemp.createTemp(
            'permission-earlier-inspection-',
          );
          final port = _EarlierInspection();
          final w = await NoteWorkspace.open(
            localDirectory: Directory('${root.path}/local'),
            vaultDirectory: await Directory('${root.path}/vault').create(),
            notifications: port,
          );
          addTearDown(() async {
            if (!port.answer.isCompleted) {
              port.answer.complete(NotificationPermission.denied);
            }
            if (!port.earlier.isCompleted) {
              port.earlier.complete(
                const NotificationSnapshot(
                  permission: NotificationPermission.denied,
                ),
              );
            }
            await w.close();
            await root.delete(recursive: true);
          });
          port.holdAt = port.inspections + inspectionOffset;
          final previous = w.reconcileReminders();
          await port.earlierEntered.future.timeout(const Duration(seconds: 1));
          final asking = w.requestNotificationPermission();
          await port.entered.future;
          final saving = w.captureText(
            title: '较早的系统检查',
            text: '旧检查尚未返回时也可以保存。',
          );
          var savedBeforeAnswer = false;
          try {
            await saving.timeout(const Duration(seconds: 1));
            savedBeforeAnswer = true;
          } on TimeoutException {
            // Release both external futures on RED, without obscuring the failure.
          } finally {
            port.answer.complete(NotificationPermission.denied);
            if (!savedBeforeAnswer) {
              port.earlier.complete(
                const NotificationSnapshot(
                  permission: NotificationPermission.denied,
                ),
              );
            }
            await Future.wait([previous, asking, saving]);
          }
          expect(
            savedBeforeAnswer,
            isTrue,
            reason: 'an inspection started before permission must yield the local mutation queue',
          );
          expect(w.notes.single.status, NoteStatus.localSaved);
          expect(
            await File(w.notes.single.sourcePath).readAsString(),
            '旧检查尚未返回时也可以保存。',
          );
          expect(w.notificationPermission, NotificationPermission.denied);
          await w.close().timeout(const Duration(seconds: 1));
          final inspections = port.inspections;
          if (lateError) {
            port.earlier.completeError(
              StateError('controlled late inspection failure'),
            );
          } else {
            port.earlier.complete(
              const NotificationSnapshot(
                permission: NotificationPermission.allowed,
              ),
            );
          }
          await Future<void>.delayed(Duration.zero);
          expect(port.inspections, inspections);
          expect(w.notificationPermission, NotificationPermission.denied);
          expect(port.requests, 1);
        },
      );
    }
  }
  for (final inspectAlsoWaits in [false, true]) {
    test(
      'a pending system permission callback does not block local text capture (inspect waits: $inspectAlsoWaits)',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'permission-pending-',
        );
        final port = _DeferredPermission(inspectAlsoWaits: inspectAlsoWaits);
        final w = await NoteWorkspace.open(
          localDirectory: Directory('${root.path}/local'),
          vaultDirectory: await Directory('${root.path}/vault').create(),
          notifications: port,
        );
        addTearDown(() async {
          if (!port.answer.isCompleted) {
            port.answer.complete(NotificationPermission.denied);
          }
          await w.close();
          await root.delete(recursive: true);
        });
        final asking = w.requestNotificationPermission();
        await port.entered.future;
        final saving = w.captureText(
          title: '权限仍待处理',
          text: '系统弹窗未回答时，本地想法也必须可以保存。',
        );
        var savedBeforePermissionAnswer = false;
        try {
          await saving.timeout(const Duration(seconds: 1));
          savedBeforePermissionAnswer = true;
        } on TimeoutException {
          // Resolve the external callback only after measuring the exact symptom,
          // so the RED run also drains cleanly instead of hanging test teardown.
        } finally {
          port.answer.complete(NotificationPermission.denied);
          await asking;
          await saving;
        }
        expect(
          savedBeforePermissionAnswer,
          isTrue,
          reason: 'local capture must complete while the OS callback is still pending',
        );
        expect(w.notes.single.status, NoteStatus.localSaved);
        expect(
          await File(w.notes.single.sourcePath).readAsString(),
          '系统弹窗未回答时，本地想法也必须可以保存。',
        );
        expect(port.requests, 1);
        expect(w.notificationPermission, NotificationPermission.denied);
      },
    );
  }
  test('permission waiting keeps desired reminders durable and resumes coordination only after an answer', () async {
    final root = await Directory.systemTemp.createTemp('permission-desired-');
    final port = _DeferredPermission(inspectAlsoWaits: true);
    final w = await NoteWorkspace.open(
      localDirectory: Directory('${root.path}/local'),
      vaultDirectory: await Directory('${root.path}/vault').create(),
      notifications: port,
    );
    addTearDown(() async {
      if (!port.answer.isCompleted) {
        port.answer.complete(NotificationPermission.denied);
      }
      await w.close();
      await root.delete(recursive: true);
    });
    final asking = w.requestNotificationPermission();
    await port.entered.future;
    final askingAgain = w.requestNotificationPermission();
    final before = port.inspections;
    final note = await w
        .captureText(title: '待权限安排', text: '买电池；也许联系同事。')
        .timeout(const Duration(seconds: 1));
    await w
        .resolveNoteActions(
          note.id,
          kind: NoteKind.todo,
          actions: [
            const WorkspaceAction(
              id: 'buy',
              text: '买电池',
              decision: ActionDecision.confirmed,
            ),
            const WorkspaceAction(
              id: 'ask',
              text: '联系同事',
              reason: 'hypothesis',
            ),
          ],
        )
        .timeout(const Duration(seconds: 1));
    expect(w.reminders.single.status, ReminderStatus.pending);
    expect(w.pendingConfirmationItems.single.noteId, note.id);
    expect(w.notificationPermission, NotificationPermission.unknown);
    expect(port.scheduled, isEmpty);
    expect(port.inspections, before);
    expect(port.requests, 1);
    port.answer.complete(NotificationPermission.allowed);
    await Future.wait([asking, askingAgain]);
    expect(w.notificationPermission, NotificationPermission.allowed);
    expect(w.reminders.single.status, ReminderStatus.scheduled);
    expect(
      port.scheduled.values.map((r) => r.payload['kind']),
      containsAll(['actionReminder', 'pendingConfirmation']),
    );
    final schedules = port.schedules;
    await w.reconcileReminders();
    expect(port.schedules, schedules);
    expect(port.requests, 1);
    expect(w.notes.single.originalText, note.text);
  });

  test(
    'closing a workspace does not wait for or apply a late permission answer',
    () async {
      final root = await Directory.systemTemp.createTemp('permission-close-');
      final port = _DeferredPermission(inspectAlsoWaits: true);
      final w = await NoteWorkspace.open(
        localDirectory: Directory('${root.path}/local'),
        vaultDirectory: await Directory('${root.path}/vault').create(),
        notifications: port,
      );
      addTearDown(() async {
        if (!port.answer.isCompleted) {
          port.answer.complete(NotificationPermission.denied);
        }
        await w.close();
        await root.delete(recursive: true);
      });
      final asking = w.requestNotificationPermission();
      await port.entered.future;
      await w
          .captureText(title: '关闭前保存', text: '原文保留。')
          .timeout(const Duration(seconds: 1));
      await w.close().timeout(const Duration(seconds: 1));
      final before = port.inspections;
      port.answer.complete(NotificationPermission.allowed);
      await asking;
      expect(port.inspections, before);
      expect(w.notificationPermission, NotificationPermission.unknown);
      expect(port.requests, 1);
    },
  );
}

class _DeferredPermission implements NotificationPort {
  _DeferredPermission({required this.inspectAlsoWaits});
  final bool inspectAlsoWaits;
  final entered = Completer<void>();
  final answer = Completer<NotificationPermission>();
  int requests = 0, inspections = 0, schedules = 0;
  final scheduled = <String, NotificationRequest>{};
  NotificationPermission permission = NotificationPermission.notDetermined;
  @override
  Future<NotificationSnapshot> inspect() async {
    inspections++;
    if (inspectAlsoWaits && requests > 0 && !answer.isCompleted) {
      await answer.future;
    }
    return NotificationSnapshot(
      permission: permission,
      pendingIds: scheduled.keys.toSet(),
      acceptedIds: scheduled.keys.toSet(),
    );
  }

  @override
  Future<NotificationPermission> requestPermission() async {
    requests++;
    entered.complete();
    return permission = await answer.future;
  }

  @override
  Future<void> schedule(NotificationRequest request) async {
    schedules++;
    scheduled[request.id] = request;
  }

  @override
  Future<void> cancel(String id) async {
    scheduled.remove(id);
  }
}

class _EarlierInspection extends _DeferredPermission {
  _EarlierInspection() : super(inspectAlsoWaits: false);
  int? holdAt;
  final earlierEntered = Completer<void>();
  final earlier = Completer<NotificationSnapshot>();
  @override
  Future<NotificationSnapshot> inspect() {
    if (inspections + 1 == holdAt) {
      inspections++;
      earlierEntered.complete();
      return earlier.future;
    }
    return super.inspect();
  }
}
