import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/main.dart';

import 'support/budget_fixture.dart';

import 'support/async_settle.dart';
import 'support/organize_now.dart';

class _LoopbackHttpOverrides extends HttpOverrides {}

void main() {
  testWidgets(
    'phone user can see a topic reason and confirm or ignore from the shared pending list',
    (tester) async {
      final f = BudgetFixture();
      final w = (await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(() async {
          await f.start();
          final w = f.workspaces.first;
          final n = await w.captureText(title: '使用观察', text: '首次使用工具时不清楚下一步。');
          f.modelResult = {
            'manifestVersion': 3,
            'kind': 'ordinary',
            'title': '首次使用观察',
            'body': '首次使用工具时不清楚下一步。',
            'actions': [],
            'associations': [],
            'newTopics': [
              {'title': '引导设计', 'reason': '集中分析首次使用时的困难。'},
              {'title': '新手研究', 'reason': '积累新手的体验反馈。'},
            ],
          };
          await w.organizeNow(n.id);
          return w;
        }, _LoopbackHttpOverrides()),
      ))!;
      addTearDown(() => tester.runAsync(f.close));
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(NoteAgentApp(initialWorkspace: w));
      await tester.pumpAndSettle();
      await tester.tap(find.text('待确认 1'));
      await tester.pumpAndSettle();
      expect(find.text('集中分析首次使用时的困难。'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.text('确认创建主题').first);
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await pumpUntil(tester, () => w.pendingTopicSuggestions.length == 1);
      await tester.pumpAndSettle();
      expect(w.pendingTopicSuggestions.single.title, '新手研究');
      await tester.runAsync(() async {
        await tester.tap(find.text('忽略主题建议'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await pumpUntil(
        tester,
        () => find.text('没有待确认内容。').evaluate().isNotEmpty,
      );
      await tester.pumpAndSettle();
      expect(find.text('没有待确认内容。'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('待确认 0'), findsOneWidget);
      expect(
        w.notes
            .firstWhere((n) => n.title == '首次使用观察')
            .associations
            .single
            .title,
        '引导设计',
      );
      expect(f.modelRequests.length, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
