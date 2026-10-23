import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/note_workspace.dart';
import 'package:note_agent/sync_panel.dart';

void main() {
  testWidgets(
    'to-do status never claims the note arrived, and early states are reported as awaiting their note',
    (tester) async {
      final note = WorkspaceNote(
        id: 'n',
        title: '安排',
        text: '买电池',
        createdAt: DateTime(2026),
        modifiedAt: DateTime(2026),
        notePath: '/v/安排.md',
        sourcePath: '/v/s.txt',
        status: NoteStatus.localSaved,
      );
      const offline = WorkspaceTodoSync(
        status: TaskStatusSync.offline,
        message: '',
        pendingOperations: 2,
      );
      const synced = WorkspaceTodoSync(
        status: TaskStatusSync.synced,
        message: '',
        awaitingNote: [
          TodoAwaitingNote(
            noteId: 'x',
            actionId: 'a',
            lifecycle: 1,
            completed: true,
          ),
        ],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                NoteSyncSummary(note: note, todoSync: offline),
                NoteSyncSummary(note: note, todoSync: synced),
                const TodoAwaitingNoteBanner(sync: synced),
                const TodoAwaitingNoteBanner(sync: offline),
              ],
            ),
          ),
        ),
      );
      expect(find.text('笔记同步：尚未核实'), findsNWidgets(2));
      expect(find.text('待办状态同步：离线，2 项保留在本机，联网后自动协调'), findsOneWidget);
      expect(find.text('待办状态同步：已与其他设备协调（不代表笔记已到达）'), findsOneWidget);
      expect(find.textContaining('笔记正文尚未到达本机'), findsOneWidget);
      expect(find.textContaining('1 项待办状态（1 项已完成）'), findsOneWidget);
    },
  );
}
