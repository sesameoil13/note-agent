import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/main.dart';
import 'package:note_agent/connection.dart';
import 'package:note_agent/note_workspace.dart';

void main() {
  testWidgets(
    'macOS secrets have named actions that open secure sheets and preserve cancelled drafts',
    (tester) async {
      final folder = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('secure-sheet-ui-'),
      ))!;
      final messenger = tester.binding.defaultBinaryMessenger;
      const credentials = MethodChannel('dev.noteagent/credentials');
      const secureInput = MethodChannel('dev.noteagent/secure-input');
      messenger.setMockMethodCallHandler(credentials, (call) async => null);
      final workspace = (await tester.runAsync(
        () async => NoteWorkspace.open(
          localDirectory: Directory('${folder.path}/local'),
          vaultDirectory: await Directory('${folder.path}/vault').create(),
          connection: WorkspaceConnection(
            secureStore: PlatformSecureCredentialStore(),
            pairingEndpoint: Uri.parse('https://pairing.example.test'),
          ),
        ),
      ))!;
      Completer<String?>? sheet;
      Map<Object?, Object?>? request;
      messenger.setMockMethodCallHandler(secureInput, (call) async {
        expect(call.method, 'edit');
        request = call.arguments as Map<Object?, Object?>;
        sheet = Completer<String?>();
        return sheet!.future;
      });
      // Stub the retired embedding's OS boundary too: a regression must fail
      // because its named editing action is absent, not because a plugin is absent.
      final embeddedIds = <int>[];
      messenger.setMockMethodCallHandler(SystemChannels.platform_views, (
        call,
      ) async {
        if (call.method == 'create') {
          final id = (call.arguments as Map)['id'] as int;
          embeddedIds.add(id);
          messenger.setMockMethodCallHandler(
            MethodChannel('dev.noteagent/secure-input/$id'),
            (_) async => null,
          );
        }
        return null;
      });
      addTearDown(() async {
        messenger.setMockMethodCallHandler(credentials, null);
        messenger.setMockMethodCallHandler(secureInput, null);
        messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
        for (final id in embeddedIds) {
          messenger.setMockMethodCallHandler(
            MethodChannel('dev.noteagent/secure-input/$id'),
            null,
          );
        }
        await tester.runAsync(() async {
          await workspace.close();
          await folder.delete(recursive: true);
        });
      });
      tester.view.physicalSize = const Size(1280, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final semantics = tester.ensureSemantics();
      try {
        await tester.pumpWidget(NoteAgentApp(initialWorkspace: workspace));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('连接与设备'));
        await tester.pumpAndSettle();
        Future<void> open(String label) async {
          expect(find.bySemanticsLabel('填写 $label'), findsOneWidget);
          final node = tester.getSemantics(find.bySemanticsLabel('填写 $label'));
          final data = node.getSemanticsData();
          expect(data.flagsCollection.isButton, isTrue);
          expect(data.flagsCollection.isEnabled, ui.Tristate.isTrue);
          expect(data.hasAction(ui.SemanticsAction.tap), isTrue);
          tester.binding.performSemanticsAction(
            ui.SemanticsActionEvent(
              type: ui.SemanticsAction.tap,
              viewId: tester.view.viewId,
              nodeId: node.id,
            ),
          );
          await tester.pump();
          expect(request!['label'], label);
        }

        await open('百炼 API Key');
        expect(request!['text'], isEmpty);
        const fixture = 'sk-or-v1-accessibility-only-test-key';
        sheet!.complete(fixture);
        await tester.pumpAndSettle();
        expect(find.text('已填写，尚未提交。'), findsOneWidget);
        expect(find.text(fixture), findsNothing);
        expect(
          tester
              .binding
              .renderViews
              .single
              .owner!
              .semanticsOwner!
              .rootSemanticsNode!
              .toStringDeep(),
          isNot(contains(fixture)),
        );
        await open('百炼 API Key');
        expect(request!['text'], fixture);
        sheet!.complete(null); // Cancel must keep the previous draft.
        await tester.pumpAndSettle();
        await open('百炼 API Key');
        expect(request!['text'], fixture);
        sheet!.complete(''); // An empty native result cannot replace the draft.
        await tester.pumpAndSettle();
        await open('百炼 API Key');
        expect(request!['text'], fixture);
        sheet!.complete('short');
        await tester.pumpAndSettle();
        await tester.tap(find.text('检测并安全保存'));
        await tester.pumpAndSettle();
        expect(find.text('请输入完整的阿里云百炼 API Key。'), findsWidgets);
        await open('首次启用码');
        expect(request!['text'], isEmpty);
        sheet!.complete(null);
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      } finally {
        semantics.dispose();
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'connection entry exposes a named accessible press action before vault selection',
    (tester) async {
      const workspaceChannel = MethodChannel('dev.noteagent/workspace');
      const credentialsChannel = MethodChannel('dev.noteagent/credentials');
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(workspaceChannel, (call) async {
        if (call.method == 'restoreLocation') {
          return {'localDirectory': Directory.systemTemp.path};
        }
        throw PlatformException(code: 'unexpected', message: call.method);
      });
      // Past the first-run sequence (put off with 稍后), so no modal covers
      // the header entry.
      messenger.setMockMethodCallHandler(credentialsChannel, (call) async {
        if (call.method == 'read') {
          return '{"firstRun":{"started":true,"firstDevice":true,"finished":true}}';
        }
        throw PlatformException(code: 'unexpected', message: call.method);
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(workspaceChannel, null);
        messenger.setMockMethodCallHandler(credentialsChannel, null);
      });
      tester.view.physicalSize = const Size(1280, 960);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final semantics = tester.ensureSemantics();
      try {
        await tester.pumpWidget(const NoteAgentApp());
        await tester.pumpAndSettle();
        expect(find.text('先选择本地笔记库'), findsOneWidget);
        final entry = tester.getSemantics(find.byTooltip('连接与设备'));
        final data = entry.getSemanticsData();
        expect(data.label, '连接与设备');
        expect(data.flagsCollection.isButton, isTrue);
        expect(data.flagsCollection.isEnabled, ui.Tristate.isTrue);
        expect(data.hasAction(ui.SemanticsAction.tap), isTrue);

        tester.binding.performSemanticsAction(
          ui.SemanticsActionEvent(
            type: ui.SemanticsAction.tap,
            viewId: tester.view.viewId,
            nodeId: entry.id,
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('连接与设备'), findsOneWidget);
        expect(find.widgetWithText(TextField, '百炼 API Key'), findsOneWidget);
        expect(find.text('尚未连接阿里云百炼。'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      } finally {
        semantics.dispose();
      }
    },
  );
}
