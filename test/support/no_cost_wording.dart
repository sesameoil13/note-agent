import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Budget, estimate or cost wording (ADR 0004). The Bailian console and a
/// top-up are only mentioned when the balance runs out.
final costWording = RegExp(
  r'预算|预估|估算|额度|费用|扣费|计费|收费|预留|月上限|月消耗|预付|账单|余额|¥|budget',
  caseSensitive: false,
);

/// Fails when any text on screen (labels, buttons, menus, fields) talks
/// about a budget, an estimate or cost.
void expectNoCostWording(WidgetTester tester) {
  final shown = [
    for (final t in tester.widgetList<RichText>(find.byType(RichText)))
      t.text.toPlainText(),
    for (final t in tester.widgetList<EditableText>(find.byType(EditableText)))
      t.controller.text,
    for (final t in tester.widgetList<Tooltip>(find.byType(Tooltip)))
      t.message ?? '',
    for (final t in tester.widgetList<Semantics>(find.byType(Semantics)))
      t.properties.label ?? '',
  ];
  expect(shown.where(costWording.hasMatch).toList(), isEmpty);
}
