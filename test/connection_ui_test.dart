import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/main.dart';
import 'package:note_agent/connection.dart';
import 'package:note_agent/note_workspace.dart';

void main() {
  testWidgets(
    'macOS connection secrets use labelled native secure input without Flutter text exposure',
    (tester) async {
      final folder = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('secure-input-ui-'),
      ))!;
      final messenger = tester.binding.defaultBinaryMessenger;
      const credentials = MethodChannel('dev.noteagent/credentials');
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
      final nativeFields = <String, int>{};
      final nativeState = <int, Map<Object?, Object?>>{};
      messenger.setMockMethodCallHandler(SystemChannels.platform_views, (
        call,
      ) async {
        if (call.method == 'create') {
          final args = call.arguments as Map<Object?, Object?>;
          expect(args['viewType'], 'dev.noteagent/secure-input');
          final bytes = args['params'] as Uint8List;
          final params = const StandardMessageCodec().decodeMessage(
            ByteData.sublistView(bytes),
          ) as Map<Object?, Object?>;
          final id = args['id'] as int;
          nativeFields[params['label'] as String] = id;
          nativeState[id] = params;
          messenger.setMockMethodCallHandler(
            MethodChannel('dev.noteagent/secure-input/$id'),
            (update) async {
              if (update.method == 'update') {
                nativeState[id] = update.arguments as Map<Object?, Object?>;
              }
              return null;
            },
          );
        }
        return null;
      });
      addTearDown(() async {
        messenger.setMockMethodCallHandler(credentials, null);
        messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
        for (final id in nativeFields.values) {
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
        expect(nativeFields.keys, containsAll(['OpenRouter API Key', '首次启用码']));
        for (final id in nativeFields.values) {
          expect(nativeState[id]!['enabled'], isTrue);
        }
        // The macOS bridge must receive a native platform node, never a Flutter
        // editable node that the engine turns into an ordinary NSTextField.
        final nodes = <SemanticsNode>[];
        void collect(SemanticsNode node) {
          nodes.add(node);
          node.visitChildren((child) {
            collect(child);
            return true;
          });
        }

        collect(
          tester
              .binding
              .renderViews
              .single
              .owner!
              .semanticsOwner!
              .rootSemanticsNode!,
        );
        expect(
          nodes.map((node) => node.platformViewId),
          containsAll(nativeFields.values),
        );
        expect(
          nodes.where(
            (node) => node.getSemanticsData().flagsCollection.isObscured,
          ),
          isEmpty,
        );
        const fixture = 'sk-or-v1-accessibility-only-test-key';
        final keyId = nativeFields['OpenRouter API Key']!;
        final channel = MethodChannel('dev.noteagent/secure-input/$keyId');
        tester.binding.channelBuffers.push(
          channel.name,
          channel.codec.encodeMethodCall(const MethodCall('changed', fixture)),
          (_) {},
        );
        await tester.pumpAndSettle();
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
        // The real connection action consumes what the native editor entered.
        // This deliberately invalid short replacement exercises validation without
        // a model call, HTTP request, or stored credential.
        tester.binding.channelBuffers.push(
          channel.name,
          channel.codec.encodeMethodCall(const MethodCall('changed', 'short')),
          (_) {},
        );
        await tester.pump();
        await tester.tap(find.text('检测并安全保存'));
        await tester.pumpAndSettle();
        expect(find.text('请输入完整的 OpenRouter API Key。'), findsWidgets);
        expect(nativeState[keyId]!['enabled'], isTrue);
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
      messenger.setMockMethodCallHandler(credentialsChannel, (call) async {
        if (call.method == 'read') return null;
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
        expect(find.text('选择测试笔记库'), findsOneWidget);
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
        expect(
          find.widgetWithText(TextField, 'OpenRouter API Key'),
          findsOneWidget,
        );
        expect(find.text('尚未连接 OpenRouter。'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      } finally {
        semantics.dispose();
      }
    },
  );
}
