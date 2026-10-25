# T23：跨设备同步待办并处理离线冲突

本票为 GitHub #24 的本地实现。以 NoteWorkspace 为公开入口：`completeAction`／`snoozeReminder`／`reopenAction`／`resolveNoteActions`（删除行动）照旧只改本机，并在同一 SQLite 事务里写入待发操作；`syncTodos()` 推送与拉取后协调提醒；`todoSync` 报告状态。ADR 0001、0002 继续适用：端点只传行动身份与生命周期操作，不传正文；笔记与附件仍由 Obsidian Sync 负责。

## 端点与数据

`migrations/0004_todo_sync.sql` 新增 `todo_states`（每个 `noteId:actionId` 一行：合并后的状态、版本、全局递增 `seq`）与 `todo_ops`（已接收的操作 ID、来源设备）。不改既有表。`POST /v1/todos/sync` 需已配对设备 bearer，体 `{ops: [≤25], after: cursor}`，返回 `{accepted, states, cursor, more}`；一页 20 条。查询串仍被拒绝，因此拉取也走 POST。

每个操作带随机 `opId`、`kind`（complete／snooze／reopen／remove）、`lifecycle`、设备时间 `at`，snooze 带 `until`，reopen 带新生命周期编号与 `time`（毫秒时间戳）。

## 合并规则（Worker `src/todos.mjs` 与 App `lib/todo_merge.dart` 相同）

把每个操作视为局部状态，用可交换、幂等的 join 合并，因此重复、延迟与任意到达顺序都收敛到同一结果：

- 生命周期较高者整体胜出；旧生命周期的完成／稍后提醒无效。
- 同一生命周期内完成优先；完成后该生命周期的稍后提醒被清除。完成可先于其重新开启到达，仍保持完成。
- 两次稍后提醒或两个重新开启时间之间，按设备时间较晚者胜，时间相同以操作 ID 稳定决胜（ADR 0002）。
- 删除是墓碑：之后到达的任何完成、稍后、重新开启都不能使其复活。

两端各自的 join 都对照共享用例 `test/fixtures/todo-merge-cases.json` 测试（`test/todo_merge_test.dart` 与 `services/pairing/test/merge-cases.test.mjs`），每个用例检验所有到达顺序及重复投递；改动规则时先改用例，两端测试才会同时通过。

服务端以版本条件批处理（D1 事务）写入操作记录与新状态，并发写冲突时重读重试；同一 `opId` 再次投递直接返回已接受。App 拉取时用相同 join 合并，旧页或重复页不会让本机状态后退。

## 离线与提醒

操作与本机状态同事务写入 `todo_outbox`。未配对、断网或服务错误时操作保留，重启后仍在；`todoSync.status` 为 notConnected／offline／pending／synced，信息写明“保留在本机”。恢复联网后先按顺序推送，再拉取，然后由既有 `_mutate` 核对提醒：完成或删除取消计划与系统通知；其他设备的稍后提醒以新通知标识移动同一生命周期的计划（重复拉取不再移动）；重新开启以新生命周期和所选时间重新排程。完成状态变化仍通过既有受保护替换写入本机笔记勾选。

App 在以下时机调用 `syncTodos()`：详情页完成／稍后／重新开启之后；前台处理系统通知上的完成／稍后之后；移入回收站、归档，以及回收站页面中恢复、永久清除、决定过期提醒之后；回到前台时；macOS／Android／Windows 网络恢复时（`connectivitySignals`，先核对提醒再同步；macOS 由 `NWPathMonitor` 在断网后重新可达时发出 `networkAvailable`，启动时已可达不重复发出）。未配对时不进入工作区串行队列。没有后台推送或定时轮询：App 不在前台时，其他设备的完成不会立即取消本机已排提醒（ADR 0001 已接受）。

## 部署范围：单一所有者

一个 Worker 部署只服务一个所有者的设备组：`devices` 表的 `one_owner` 唯一索引只允许一个所有者，注册需部署时的一次性设置口令，成员只能经所有者批准的配对加入。因此 `todo_states`／`todo_ops` 不按组区分，读写范围就是整个部署；每个请求都要求 `devices` 中存在的已配对设备令牌（未知令牌 401，见 `todos.test.mjs` 首项）。若将来一个部署服务多个所有者，需新增迁移为 `todo_states` 加上所有者范围，不能修改 0004。

## 正文未到

状态可能先于笔记正文到达。此时状态照常保存，`todoSync.awaitingNote` 列出这些行动，笔记列表顶部提示“已收到其他设备的 N 项待办状态……笔记正文尚未到达本机”；正文（同 ID 笔记）到达后自动套用（例如已完成则不排提醒）。详情页的“待办状态同步”只说明状态协调，并注明“不代表笔记已到达”。

## 已验证（本机 Miniflare/workerd，无远程调用）

- `services/pairing` `pnpm test`：11 项通过，其中新增 `test/todos.test.mjs` 5 项（授权与边界、重复投递幂等与完成优先、重新开启与乱序、删除墓碑、游标分页）。
- `test/todo_sync_test.dart` 6 项：两个独立工作区（各自笔记库、SQLite、通知端口）经真实本机 Workerd + D1 与可断网代理配对后：完成传播并取消对方提醒；双方离线操作跨重启保留、晚到的稍后提醒不覆盖完成；重新开启传播为新生命周期且旧通知按钮无效；稍后提醒移动对方计划且只移动一次；正文未到时如实列出并在正文到达后套用；删除传播且不能被对方晚到的稍后提醒复活。
- `test/sync_workspace_test.dart` 新增未配对时操作保留本机；`test/todo_sync_ui_test.dart` 1 项检查界面文字不把状态协调说成笔记到达。
- `flutter analyze` 无问题。

全量 `flutter test` 在本机高负载（load average 约 50）下，`reminder_ui_test`、`document_processing_ui_test`、`compact_budget_navigation_test` 等依赖固定延时的界面测试在未改动的基线上同样失败；本票新增测试均通过。

## 尚未验证（需真实远端／设备）

- 未执行 migration 0004 或部署 Worker；远程 D1 的并发、Free CPU／额度未实测。
- 未在实际 macOS／Android 设备之间验收：真实网络切换、App 后台时的提醒残留、系统通知取消。
- 真实 Obsidian Sync 同时传来勾选修改时，两端都写勾选可能产生 Obsidian 自身的合并情况，尚未观察。
- Android 仍无待办提醒通知适配（T21）；Windows 暂停。
