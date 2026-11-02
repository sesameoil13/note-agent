import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/main.dart';

import 'support/ai_fixture.dart';
import 'support/async_settle.dart';

class _LoopbackHttpOverrides extends HttpOverrides {}

/// The screen side of #39: 失败 · 重试 on a capture, and the messages that
/// pause all sending for a rejected key or an empty balance.
void main() {
  Future<AiFixture> saveText(WidgetTester tester, List<int> statuses) async {
    final f = AiFixture()..modelStatuses.addAll(statuses);
    await tester.runAsync(() => f.start(devices: 1));
    addTearDown(() => tester.runAsync(f.close));
    tester.view.physicalSize = const Size(1280, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(NoteAgentApp(initialWorkspace: f.workspaces.first));
    await pumpUntil(tester);
    await tester.enterText(find.widgetWithText(TextField, '标题'), '想法');
    await tester.enterText(find.widgetWithText(TextField, '正文'), '今天的想法。');
    await tester.runAsync(() async {
      await tester.tap(find.text('保存文字'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await pumpUntil(tester, () => f.modelRequests.isNotEmpty);
    await pumpUntil(tester);
    return f;
  }

  Future<void> tapAndWait(WidgetTester tester, String label) async {
    await tester.runAsync(() async {
      await tester.tap(find.text(label));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await pumpUntil(tester);
  }

  testWidgets('a failed capture shows 失败 with 重试, which sends it again', (
    tester,
  ) async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final f = await saveText(tester, [400]);
      expect(find.textContaining('整理：失败'), findsOneWidget);

      await tapAndWait(tester, '重试');
      await pumpUntil(
        tester,
        () => find.textContaining('整理：已整理').evaluate().isNotEmpty,
      );

      expect(find.textContaining('整理：已整理'), findsOneWidget);
      expect(find.text('重试'), findsNothing);
      expect(f.modelRequests, hasLength(2));
      await tester.pumpWidget(const SizedBox());
    }, _LoopbackHttpOverrides());
  });

  testWidgets('an empty balance shows the top-up message, and 继续发送 resumes', (
    tester,
  ) async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final f = await saveText(tester, [402]);
      expect(find.textContaining('余额不足，自动发送已暂停'), findsOneWidget);
      expect(find.textContaining('整理：等待发送'), findsOneWidget);

      await tapAndWait(tester, '继续发送');
      await pumpUntil(
        tester,
        () => find.textContaining('整理：已整理').evaluate().isNotEmpty,
      );

      expect(find.textContaining('自动发送已暂停'), findsNothing);
      expect(f.modelRequests, hasLength(2));
      await tester.pumpWidget(const SizedBox());
    }, _LoopbackHttpOverrides());
  });

  testWidgets('a rejected key shows the reconnect message, which opens the connection', (
    tester,
  ) async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final f = await saveText(tester, [401]);
      expect(find.textContaining('重新连接阿里云百炼 Key'), findsOneWidget);
      expect(find.text('继续发送'), findsNothing);

      await tapAndWait(tester, '重新连接');
      expect(find.text('连接与设备'), findsWidgets);
      expect(find.text('检测并安全保存'), findsOneWidget);
      expect(f.modelRequests, hasLength(1));
      await tester.pumpWidget(const SizedBox());
    }, _LoopbackHttpOverrides());
  });
}
