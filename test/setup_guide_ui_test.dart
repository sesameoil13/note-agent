import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/note_workspace.dart';
import 'package:note_agent/setup_screen.dart';

import 'support/budget_fixture.dart';

import 'package:note_agent/connection.dart';

/// Old vaults and backups are synthetic temporary folders "picked" through a
/// mocked system panel; the App never looks for a real vault by itself.
void main() {
  late Directory root;
  late NoteWorkspace workspace;
  final picks = <String?>[];
  const channel = MethodChannel('dev.noteagent/workspace');

  Future<void> pumpSetup(WidgetTester tester) async {
    workspace = (await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('setup-guide-');
      for (final dir in ['old', 'backup']) {
        await File('${root.path}/$dir/日记.md').create(recursive: true);
        await File('${root.path}/$dir/日记.md').writeAsString('旧库原文');
        await File('${root.path}/$dir/.obsidian/app.json')
            .create(recursive: true);
      }
      return NoteWorkspace.open(
        localDirectory: Directory('${root.path}/local'),
        vaultDirectory: await Directory('${root.path}/新库').create(),
        connection: WorkspaceConnection(secureStore: BudgetMemoryStore()),
      );
    }))!;
    addTearDown(
      () => tester.runAsync(() async {
        await workspace.close();
        await root.delete(recursive: true);
      }),
    );
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'chooseFolder') return picks.removeAt(0);
      throw PlatformException(code: 'unexpected');
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: SetupScreen(
          workspace: workspace,
          connection: workspace.connection,
        ),
      ),
    );
  }

  Future<void> tapAndSettle(WidgetTester tester, Finder target) async {
    await tester.scrollUntilVisible(
      target,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.runAsync(() async {
      await tester.tap(target);
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pumpAndSettle();
  }

  testWidgets('the guide names the exact build for bug reports', (
    tester,
  ) async {
    await pumpSetup(tester);
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final version = RegExp(
      r'^version: (\S+)$',
      multiLine: true,
    ).firstMatch(pubspec)![1];
    expect(find.text('版本 $version · 构建 dev'), findsOneWidget);
  });

  testWidgets(
    'the guide summary separates App-verified steps from user reports',
    (tester) async {
      await pumpSetup(tester);
      expect(find.text('设置进度'), findsOneWidget);
      expect(find.textContaining('App 已获得本地库授权：新库'), findsOneWidget);
      expect(find.text('App 已验证'), findsOneWidget);
      expect(find.text('未完成'), findsNWidgets(5));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'the App compares a picked old vault and backup read-only and shows the result',
    (tester) async {
      await pumpSetup(tester);
      picks.addAll(['${root.path}/old', '${root.path}/backup']);
      await tapAndSettle(tester, find.text('选择旧库与备份，只读核对'));
      expect(find.textContaining('App 已核对：旧库 2 个文件'), findsOneWidget);
      expect(find.textContaining('包含 .obsidian 设置'), findsOneWidget);
      expect(workspace.setup.backupVerifiedAt, isNotNull);
      await tester.scrollUntilVisible(
        find.textContaining('App 已只读比对旧库与备份'),
        -300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.textContaining('App 已只读比对旧库与备份'), findsOneWidget);

      await tester.runAsync(
        () => File('${root.path}/backup/日记.md').writeAsString('截断'),
      );
      picks.addAll(['${root.path}/old', '${root.path}/backup']);
      await tapAndSettle(tester, find.text('选择旧库与备份，只读核对'));
      expect(find.textContaining('备份不完整'), findsOneWidget);
      expect(find.textContaining('大小不一致：日记.md'), findsOneWidget);
      expect(workspace.setup.backupVerifiedAt, isNull);
      expect(
        await tester.runAsync(
          () => File('${root.path}/old/日记.md').readAsString(),
        ),
        '旧库原文',
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('cancelling a folder pick leaves the backup check unchanged', (
    tester,
  ) async {
    await pumpSetup(tester);
    picks.addAll([null]);
    await tapAndSettle(tester, find.text('选择旧库与备份，只读核对'));
    expect(find.textContaining('未选择文件夹，未进行核对'), findsOneWidget);
    expect(workspace.setup.backupVerifiedAt, isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
