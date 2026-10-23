// The Worker's merge rules against the cases the App is tested with too
// (test/todo_merge_test.dart at the repository root), so the two cannot drift.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { joinMark, joinTodo } from "../src/todos.mjs";

const cases = JSON.parse(
  await readFile(
    new URL("../../../test/fixtures/todo-merge-cases.json", import.meta.url),
    "utf8",
  ),
);

function* orders(items) {
  if (items.length <= 1) return yield items;
  for (let i = 0; i < items.length; i++)
    for (const tail of orders(items.filter((_, j) => j !== i)))
      yield [items[i], ...tail];
}

for (const [group, join] of [
  ["todo", joinTodo],
  ["mark", joinMark],
])
  for (const c of cases[group])
    test(`${group}: ${c.name}`, () => {
      for (const order of orders(c.states)) {
        // Duplicated delivery of every state changes nothing.
        let merged = null;
        for (const s of [...order, ...order]) merged = join(merged, s);
        assert.deepEqual(merged, c.expected, JSON.stringify(order));
      }
    });
