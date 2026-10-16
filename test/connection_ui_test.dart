import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/main.dart';

void main() {
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
