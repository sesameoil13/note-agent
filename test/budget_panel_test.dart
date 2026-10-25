import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/budget_panel.dart';
import 'package:note_agent/connection.dart';
import 'package:note_agent/note_workspace.dart';

import 'support/budget_fixture.dart';

void main() {
  testWidgets(
    'an unavailable shared ledger displays unknown amounts rather than verified zero spending or thirty yuan remaining',
    (tester) async {
      final fixture = (await tester.runAsync(() async {
        final root = await Directory.systemTemp.createTemp('budget-panel-');
        final workspace = await NoteWorkspace.open(
          localDirectory: Directory('${root.path}/local'),
          vaultDirectory: await Directory('${root.path}/vault').create(),
          connection: WorkspaceConnection(secureStore: BudgetMemoryStore()),
        );
        return (root, workspace);
      }))!;
      final (root, workspace) = fixture;
      addTearDown(
        () => tester.runAsync(() async {
          await workspace.close();
          await root.delete(recursive: true);
        }),
      );
      await tester.pumpWidget(
        MaterialApp(home: BudgetPanel(workspace: workspace)),
      );
      await tester.pumpAndSettle();
      expect(workspace.budget.connected, isFalse);
      expect(find.textContaining(r'本月已结算费用 $0.000000'), findsNothing);
      expect(find.textContaining('剩余额度 ¥30'), findsNothing);
      expect(find.textContaining('本月已结算费用 未知'), findsOneWidget);
      expect(find.textContaining('剩余额度 未知'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
}
