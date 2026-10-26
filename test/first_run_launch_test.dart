import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/main.dart';

/// The App launched through its platform channels: the OS keychain holds
/// the device's connection state (and first-run answers); the workspace
/// channel says whether a vault was chosen before.
void main() {
  late Directory root;
  String? keychain;
  const credentials = MethodChannel('dev.noteagent/credentials');
  const workspace = MethodChannel('dev.noteagent/workspace');

  Future<void> launch(
    WidgetTester tester, {
    Map<String, Object?>? firstRun,
    bool hadVault = false,
  }) async {
    root = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('first-run-launch-'),
    ))!;
    await tester.runAsync(() => Directory('${root.path}/vault').create());
    addTearDown(() => tester.runAsync(() => root.delete(recursive: true)));
    keychain = firstRun == null ? null : jsonEncode({'firstRun': firstRun});
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(credentials, (call) async {
      switch (call.method) {
        case 'read':
          return keychain;
        case 'write':
          keychain = (call.arguments as Map)['value'] as String;
          return null;
      }
      return null;
    });
    messenger.setMockMethodCallHandler(workspace, (call) async {
      if (call.method == 'restoreLocation') {
        return {
          'localDirectory': '${root.path}/local',
          if (hadVault) 'vaultDirectory': '${root.path}/vault',
        };
      }
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(credentials, null);
      messenger.setMockMethodCallHandler(workspace, null);
    });
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      await tester.pumpWidget(const NoteAgentApp());
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pumpAndSettle();
  }

  Map<String, dynamic> storedFirstRun() =>
      (jsonDecode(keychain!) as Map)['firstRun'] as Map<String, dynamic>;

  Finder inModal(String text) =>
      find.descendant(of: find.byType(Dialog), matching: find.text(text));

  testWidgets('a new install opens the first modal instead of the setup list', (
    tester,
  ) async {
    await launch(tester);
    expect(inModal('开始'), findsOneWidget);
    expect(find.text('设置进度'), findsNothing);
    await tester.tap(inModal('开始'));
    await tester.pumpAndSettle();
    expect(inModal('这是你的第一台设备吗？'), findsOneWidget);
    expect(storedFirstRun()['started'], isTrue);
  });

  testWidgets('an install set up before this version opens straight to work', (
    tester,
  ) async {
    await launch(tester, hadVault: true);
    expect(find.byType(Dialog), findsNothing);
    expect(find.textContaining('还有'), findsNothing);
    expect(storedFirstRun()['finished'], isTrue);
  });

  testWidgets('quitting mid-way reopens at the unfinished modal', (
    tester,
  ) async {
    await launch(tester, firstRun: {'started': true, 'firstDevice': true});
    expect(inModal('连接 AI'), findsOneWidget);
  });

  testWidgets('steps put off show one banner whose 继续 reopens the sequence', (
    tester,
  ) async {
    await launch(
      tester,
      hadVault: true,
      firstRun: {
        'started': true,
        'firstDevice': true,
        'hasOldVault': false,
        'notificationsAsked': true,
        'finished': true,
        'skipped': ['connectAi', 'obsidian'],
      },
    );
    expect(find.byType(Dialog), findsNothing);
    expect(find.text('还有 2 步未完成'), findsOneWidget);
    await tester.tap(find.text('继续'));
    await tester.pumpAndSettle();
    expect(inModal('连接 AI'), findsOneWidget);
    // The full list is still there, as Settings.
    expect(find.byTooltip('设置'), findsOneWidget);
  });
}
