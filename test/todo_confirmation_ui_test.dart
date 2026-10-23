import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/main.dart';
import 'package:note_agent/note_workspace.dart';
import 'package:note_agent/action_confirmation_screen.dart';

import 'support/async_settle.dart';

void main() {
  testWidgets(
    'same action screen exposes retry after a failed save and completes the original change',
    (tester) async {
      final fixture = (await tester.runAsync(() async {
        final root = await Directory.systemTemp.createTemp('todo-ui-retry-');
        final storage = _FailActionStorage(
          await Directory('${root.path}/vault').create(),
        );
        final w = await NoteWorkspace.open(
          localDirectory: Directory('${root.path}/local'),
          vaultStorage: storage,
        );
        final n = await w.captureText(title: '保存恢复', text: '需要买电池。');
        return (root, storage, w, n);
      }))!;
      final (root, storage, w, n) = fixture;
      addTearDown(
        () => tester.runAsync(() async {
          await w.close();
          await root.delete(recursive: true);
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: ActionConfirmationScreen(workspace: w, noteId: n.id),
        ),
      );
      await tester.enterText(find.widgetWithText(TextField, '行动内容'), '买两节电池');
      await tester.tap(find.text('确认由我执行'));
      await tester.scrollUntilVisible(
        find.text('保存修正（不调用模型）'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      storage.fail = true;
      await tester.runAsync(() async {
        await tester.tap(find.text('保存修正（不调用模型）'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await pumpUntil(tester, () => w.notes.single.actionSavePending);
      await tester.pumpAndSettle();
      expect(w.notes.single.actionSavePending, isTrue);
      expect(find.text('重试保存修正'), findsOneWidget);
      storage.fail = false;
      await tester.ensureVisible(find.text('重试保存修正'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.text('重试保存修正'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await pumpUntil(tester, () => !w.notes.single.actionSavePending);
      await tester.pumpAndSettle();
      expect(w.notes.single.actionSavePending, isFalse);
      expect(w.notes.single.kind, NoteKind.todo);
      expect(w.notes.single.actions.single.text, '买两节电池');
      expect(w.notes.single.actions.single.actionConfirmed, isTrue);
      expect(w.notes.single.originalText, n.text);
      expect(w.textJobs, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'phone user can find pending actions, correct and accept locally, then retain only a note',
    (tester) async {
      final fixture = (await tester.runAsync(() async {
        final root = await Directory.systemTemp.createTemp('todo-ui-');
        final w = await NoteWorkspace.open(
          localDirectory: Directory('${root.path}/local'),
          vaultDirectory: await Directory('${root.path}/vault').create(),
        );
        final n = await w.captureText(title: '行动核对', text: '他说可以考虑购买电池。');
        await w.resolveNoteActions(
          n.id,
          kind: NoteKind.todo,
          actions: [const WorkspaceAction(text: '购买电池', reason: 'quote')],
          body: '记录别人的建议。',
        );
        return (root, w);
      }))!;
      final (root, w) = fixture;
      addTearDown(
        () => tester.runAsync(() async {
          await w.close();
          await root.delete(recursive: true);
        }),
      );
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(NoteAgentApp(initialWorkspace: w));
      await tester.pumpAndSettle();
      expect(find.text('待确认 1'), findsOneWidget);
      await tester.tap(find.text('待确认 1'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('行动核对'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, '行动内容'), '我来买两节电池');
      await tester.tap(find.text('确认由我执行'));
      await tester.scrollUntilVisible(
        find.text('保存修正（不调用模型）'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.runAsync(() async {
        await tester.tap(find.text('保存修正（不调用模型）'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(w.notes.single.actions.single.text, '我来买两节电池');
      expect(w.notes.single.actions.single.actionConfirmed, isTrue);
      expect(w.pendingActionNotes, isEmpty);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('历史记录'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('行动核对'));
      await tester.pumpAndSettle();
      expect(find.text('待办'), findsOneWidget);
      expect(find.text('摘要'), findsOneWidget);
      await tester.tap(find.text('修正类型与行动'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('仅保留为普通笔记'),
        -300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.runAsync(() async {
        await tester.tap(find.text('仅保留为普通笔记'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(w.notes.single.kind, NoteKind.ordinary);
      expect(w.notes.single.actions, isEmpty);
      expect(w.notes.single.originalText, '他说可以考虑购买电池。');
      expect(w.textJobs, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

class _FailActionStorage extends DirectoryVaultStorage {
  _FailActionStorage(super.directory);
  bool fail = false;
  @override
  Future<void> replaceText(
    String path,
    String expected,
    String text,
    String operation,
  ) {
    if (fail && operation.startsWith('action-')) {
      throw const FileSystemException('controlled action write failure');
    }
    return super.replaceText(path, expected, text, operation);
  }
}
