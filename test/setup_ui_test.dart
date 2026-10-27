import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/connection.dart';
import 'package:note_agent/main.dart';
import 'package:note_agent/note_workspace.dart';
import 'package:note_agent/setup_screen.dart';

import 'support/budget_fixture.dart';

// Allow the existing synthetic ledger fixture's loopback HTTP transport in a
// widget test; no production endpoints or real credentials are involved.
class _LoopbackHttpOverrides extends HttpOverrides {}

void main() {
  testWidgets(
    'setup leaves the shared monthly limit and spending unknown before ledger verification',
    (tester) async {
      final workspace = (await tester.runAsync(() async {
        final root = await Directory.systemTemp.createTemp('setup-budget-');
        addTearDown(() => root.delete(recursive: true));
        return NoteWorkspace.open(
          localDirectory: Directory('${root.path}/local'),
          vaultDirectory: await Directory('${root.path}/vault').create(),
          connection: WorkspaceConnection(secureStore: BudgetMemoryStore()),
        );
      }))!;
      addTearDown(() => tester.runAsync(workspace.close));
      await tester.pumpWidget(
        MaterialApp(
          home: SetupScreen(
            workspace: workspace,
            connection: workspace.connection,
          ),
        ),
      );
      await tester.scrollUntilVisible(find.text('5 / 预付与月消耗'), 400);
      expect(find.textContaining('月预算：¥30.00'), findsNothing);
      expect(find.textContaining('共享月上限 尚未核对'), findsOneWidget);
      expect(find.textContaining('本月实际消耗 未知'), findsOneWidget);
      expect(find.textContaining('政策最多 30 元'), findsOneWidget);
      expect(find.textContaining('账户余额：未知'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'setup displays the verified shared monthly limit separately from prepaid balance',
    (tester) async {
      final fixture = BudgetFixture();
      await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(() async {
          await fixture.start();
          await fixture.workspaces.first.setMonthlyBudgetLimit(100000);
        }, _LoopbackHttpOverrides()),
      );
      addTearDown(() => tester.runAsync(fixture.close));
      final workspace = fixture.workspaces.first;
      await tester.pumpWidget(
        MaterialApp(
          home: SetupScreen(
            workspace: workspace,
            connection: workspace.connection,
          ),
        ),
      );
      await tester.scrollUntilVisible(find.text('5 / 预付与月消耗'), 400);
      expect(find.textContaining('本月预算：¥0.10'), findsOneWidget);
      expect(find.textContaining('保守折算消耗：¥0.00'), findsOneWidget);
      expect(find.textContaining('共享月上限 尚未核对'), findsNothing);
      expect(find.textContaining('账户余额：未知'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'expired vault authorization remains visible and recoverable before first setup',
    (tester) async {
      const channel = MethodChannel('dev.noteagent/workspace');
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'restoreLocation') {
          return {
            'localDirectory': Directory.systemTemp.path,
            'authorizationError': '笔记库授权已失效，请重新选择同一目录。',
          };
        }
        if (call.method == 'chooseLocation') return null;
        throw PlatformException(code: 'unexpected');
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await tester.pumpWidget(const NoteAgentApp());
      await tester.pumpAndSettle();
      expect(find.textContaining('笔记库授权已失效'), findsOneWidget);
      await tester.tap(find.text('开始设置'));
      await tester.pumpAndSettle();
      expect(find.text('需要处理'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('选择或重新授权本地库'),
        300,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('选择或重新授权本地库'));
      await tester.pumpAndSettle();
      expect(find.text('未更改笔记库，输入已保留。'), findsOneWidget);
      expect(find.text('开始设置'), findsOneWidget);
    },
  );
  testWidgets(
    'setup makes backup and remote consent explicit without changing the capture draft',
    (tester) async {
      final workspace = (await tester.runAsync(() async {
        final root = await Directory.systemTemp.createTemp('setup-ui-');
        addTearDown(() => root.delete(recursive: true));
        return NoteWorkspace.open(
          localDirectory: Directory('${root.path}/local'),
          vaultDirectory: await Directory('${root.path}/new').create(),
        );
      }))!;
      addTearDown(() => tester.runAsync(workspace.close));
      tester.view.physicalSize = const Size(1280, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(NoteAgentApp(initialWorkspace: workspace));
      await tester.enterText(find.widgetWithText(TextField, '标题'), '尚未保存的想法');
      await tester.enterText(find.widgetWithText(TextField, '正文'), '设置不能丢掉原文');
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      expect(find.textContaining('用户核对记录'), findsOneWidget);
      final consent = find.text('单独确认远程名额切换');
      await tester.scrollUntilVisible(consent, 400);
      expect(
        tester
            .widget<OutlinedButton>(
              find.ancestor(of: consent, matching: find.byType(OutlinedButton)),
            )
            .onPressed,
        isNull,
      );
      for (final text in ['我已制作并检查独立的完整旧库备份', '旧库的本地导入副本已保留，不会随远程名额切换删除']) {
        await tester.ensureVisible(find.text(text));
        await tester.runAsync(() async {
          await tester.tap(find.text(text));
          await Future<void>.delayed(const Duration(milliseconds: 20));
        });
        await tester.pumpAndSettle();
      }
      await tester.ensureVisible(consent);
      await tester.tap(consent);
      await tester.pumpAndSettle();
      await tester.tap(find.text('暂不切换'));
      await tester.pumpAndSettle();
      expect(workspace.setup.remoteSlotConsentAt, isNull);
      await tester.tap(consent);
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.text('我确认，继续到 Obsidian 核对'));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pumpAndSettle();
      expect(workspace.setup.remoteSlotConsentAt, isNotNull);
      expect(
        workspace.setup.isReported(SetupCheck.remoteSlotSwitched),
        isFalse,
      );
      expect(workspace.setup.noteSyncVerified, isFalse);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, '尚未保存的想法'), findsOneWidget);
      expect(find.widgetWithText(TextField, '设置不能丢掉原文'), findsOneWidget);
    },
  );
}
