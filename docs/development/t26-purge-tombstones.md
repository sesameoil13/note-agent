# T26：批量恢复、永久清除与删除防复活

本票为 GitHub #27 的本地实现，在 T25 的 `note_disposals` 与 T23 的待办同步上扩展。公开入口仍是 `NoteWorkspace`：

- `restoreNotes(ids)`：逐项走与 `restoreNote` 相同的恢复流程（同名改用编号标题、未来提醒以新通知标识恢复、过期提醒待决定）；每项都会尝试，失败项最后合并报告。
- `purgeNotes(ids)`：永久清除。只接受回收站中的项（任一不在回收站则整体拒绝）。确认在 App 中完成：单项“永久清除”与“全部永久清除”每次都弹出确认，并写明无法恢复、配对设备也会清除、仍被引用的附件保留，以及 Obsidian Sync 自身的历史版本不在本 App 管理范围内、不会被清除。
- `syncTodos()` 同时交换删除标记。

## 永久清除

1. 若删除尚未完成先完成删除。
2. 同一事务内：`note_disposals` 转为 `purged`（阶段 `purging`，只记录待清理文件列表），保留副本随之丢弃；清空 `notes` 行的标题、正文与行动；删除该笔记的 `action_states`、`attachments`、关联与转写更正记录；文字处理任务只保留费用记录、去掉文本；写入删除标记并排入待发队列。`notes` 行本身保留为不可见的空壳，以便任何功能都把它当作已清除。
3. 清理文件：候选只限 App 自己的 `attachments/note-agent/` 下属于该笔记的文件（来源文字、附件副本、最后副本中链接的该目录文件）以及附件的本机私有原件。笔记库中任一其他笔记（含回收站中其他项的保留副本）以路径、URL 编码路径或 `[[文件名` 引用，或其他笔记记录拥有该路径时，一律保留。用户自己放在该目录以外的文件从不删除。
4. 文件删除失败时阶段保持 `purging`，下次打开工作区继续。

`BinaryVaultStorage` 新增 `deleteFile`（桌面直接删除；Android 走 `vaultDeleteFile` → `SafVault.deleteFile`）。

## 删除标记（跨设备）

不新增迁移：标记沿用 `/v1/todos/sync`，以保留行动 ID `_note` 表示整条笔记，操作类型 `trash`／`restore`／`purge`（只能用于 `_note`，`_note` 也不接受待办类型）。Worker 的 `joinMark` 与 App 的 `_joinNoteMark` 相同：

- 清除是终态：任何之后或重复到达的删除、恢复都不能撤销。
- 删除与恢复之间按设备时间较晚者胜，操作 ID 决胜（ADR 0002）。本机连续操作的时间戳保证单调递增，即使时钟未走或回拨，本机的恢复也总在其删除之后。

App 把合并后的标记存在本机 `note_marks`，在每次同步后与打开工作区时套用：`trashed` → 本机移入回收站（取消提醒，保留副本含本机离线修改）；`restored` → 本机恢复（若原路径已有完全相同的文件，例如由 Obsidian Sync 带回，则直接采用，不产生第二份）；`purged` → 本机先删除再清除。正文尚未到达的笔记保留标记，笔记到达后的下一次同步／启动时套用；有未写入修改或仍在处理的笔记保持原状，下次再试。回收站中或已清除笔记的待办状态不再列入 `awaitingNote`。

## 重新整理的旧行动

T27 重新整理会给行动新 ID；现在应用整理结果的同一事务内，会把不再存在的旧行动写成待办墓碑（`remove`）并排入同步，配对设备不再等待或提醒旧行动。`resolveNoteActions` 与之共用 `_tombstoneActions`。

## 已验证

- `services/pairing` `pnpm test`：14 项通过（新增 3 项：标记类型边界、晚到／重复的旧恢复不撤销较新删除、清除终态）。
- `test/recycle_bin_purge_test.dart`（4 项）：清除只删自有文件并保留被其他笔记（含回收站中另一项）引用的附件与用户文件、重启后不复现、不可再恢复；回收站外的笔记不能清除；全部恢复时同名不覆盖、未来提醒恢复、过期提醒待决定；全部清除后无提醒、无待决定。
- `test/deletion_marks_test.dart`（4 项，两台设备经本机 Workerd + D1）：删除传到对方回收站并取消提醒、重复拉取不变、对方恢复后本机恢复且不重复；离线设备带旧副本并做了完成／稍后提醒，联网后被清除且不让任何一方复活（含重启后再同步）；清除先于笔记到达仍会生效；离线的旧恢复不撤销其他设备较晚的删除。
- `test/processing_recovery_test.dart` 新增：重新整理后配对设备不再保留旧行动。
- `test/recycle_bin_ui_test.dart` 新增：单项清除先确认（取消不清除）、文字声明不清除 Obsidian Sync 历史、全部恢复、全部永久清除。
- 全量 `flutter test --timeout 60s`：289 项通过；`flutter analyze` 无问题。

## 尚未验证

- 未执行远程 D1、未部署 Worker；真实设备（macOS／Android）间的删除标记与 Obsidian Sync 同时传递文件删除／恢复的交互未实测。
- Android `vaultDeleteFile` 与 `SafVault.deleteFile` 未编译、未在设备上运行。
- 清除不触及 Obsidian Sync 的版本历史及其他设备上 Obsidian 自身的回收站（`.trash`）。
- 录音／音频队列的本机私有原件不属于附件记录，清除时保留；`reminder_plans` 中已移除的计划行保留（不再生效）。
- 其他笔记中指向被清除笔记的 `[[链接]]` 不改写。
