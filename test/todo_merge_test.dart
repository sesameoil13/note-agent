import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_agent/todo_merge.dart';

/// The App's merge rules against the cases the Worker is tested with too
/// (services/pairing/test/merge-cases.test.mjs), so the two cannot drift.
void main() {
  final cases = jsonDecode(
    File('test/fixtures/todo-merge-cases.json').readAsStringSync(),
  ) as Map<String, dynamic>;

  Iterable<List<T>> orders<T>(List<T> items) sync* {
    if (items.length <= 1) {
      yield items;
      return;
    }
    for (var i = 0; i < items.length; i++) {
      final rest = [...items]..removeAt(i);
      for (final tail in orders(rest)) {
        yield [items[i], ...tail];
      }
    }
  }

  void run(
    String group,
    Map<String, dynamic>? Function(Map<String, dynamic>?, Map<String, dynamic>)
    join,
  ) {
    for (final c in (cases[group] as List).cast<Map<String, dynamic>>()) {
      test('$group: ${c['name']}', () {
        final states = (c['states'] as List).cast<Map<String, dynamic>>();
        for (final order in orders(states)) {
          // Duplicated delivery of every state changes nothing.
          Map<String, dynamic>? merged;
          for (final s in [...order, ...order]) {
            merged = join(merged, s);
          }
          expect(merged, c['expected'], reason: 'order $order');
        }
      });
    }
  }

  run('todo', joinTodoStates);
  run('mark', joinNoteMarks);
}
