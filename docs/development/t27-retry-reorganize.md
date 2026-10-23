# T27：恢复失败、纠正转写并重新整理

本票沿用 T11/T13/T17/T18 已有的重试、预算与写入保护，补齐 App 内的失败列表、转写更正和“先预览再应用”的重新整理。公开入口仍是 `NoteWorkspace`；未部署 Worker、未调用真实模型，测试只使用本机预算 harness 与合成 HTTP 边界。

## 失败列表

`NoteWorkspace.processingFailures` 汇总三类可恢复失败，每项给出唯一的“下一步安全动作”（`ProcessingRecovery`）：

| 来源 | 条件 | 下一步 |
| --- | --- | --- |
| 文字整理 | 预留失败；发送失败且无可用结果；模型结果无效 | `retry`（另行预留，可能计费） |
| 文字整理 | 失败后已重新预留 | `confirmPrepared` |
| 录音（付费管线） | 尚无完整转写 | `retry`（另行预估上传，旧尝试保留待核对） |
| 录音（付费管线） | 转写已保存但费用未核清 | `reconcileCost`（不重传） |
| 录音（付费管线） | 转写已保存且费用核清 | `reorganizeOnly`（不重传音频） |
| 录音（本机队列） | 自动重试仍在排期 | `automaticRetryScheduled` |
| 录音 / 文档 | 原件从未完整保存 | `reselectOriginal` |
| 文档提取 | 中断、写入待重试或提取失败 | `retry`（本机重新提取，不调用模型） |

`recoverProcessingFailure(id)` 只执行该一步，然后列表重新计算；已成功的阶段（完整转写、已结算的转写、已写入的整理结果）不会重做。正文已经应用、仅剩费用核对的任务不进失败列表，继续在预算面板核对；没有 generation ID 的未知费用永远不会被当作已释放。

自动重试仍是首次之外最多三次（文字：网络超时/408/429/5xx；本机录音队列：`recoverable`）。`failureKind` 记录在本机任务中：`credentials`、`balance`、`budget`/`budget_exceeded` 一律不自动重试，失败项显示 `needsAccountAction`，用户处理账户后仍可手动重试。`automaticRetriesUsed` 跨重启保留。

App：页眉在有失败项时显示“处理失败”入口（`ProcessingFailuresScreen`）。

## 更正转写

`correctTranscript(noteId, text)` 只用于录音笔记：通过受保护替换改写 `attachments/note-agent/<id>.txt`，`WorkspaceNote.originalText` 随即为更正文本；原音、整理正文、提醒均不变，不调用模型。计划先写入本机 `source_corrections`，崩溃后打开时用同一幂等替换补完。若转写文件已在别处修改（较新的内容），拒绝并保留外部内容。首个机器转写保留在本机表中备查。整理任务已预留或发送时不允许更正，避免发送内容与原文不符。

## 重新整理预览

1. `prepareReorganization(noteId)` 以当前完整原文（录音即更正后的转写）新建独立文字任务并原子预留，不调用模型；同一笔记已有待发送任务或未处理预览时拒绝。
2. `previewReorganization(jobId)` 发送（可能计费，沿用最多三次自动重试与验证），结果只存为 `reorganizationPreviews`，笔记不变。重复点击共享同一请求。
3. `applyReorganization(jobId)` 先核对笔记自预估时起未被修改（正文、修改时间、笔记文件与原文均一致），再走既有的崩溃安全写入（`writePlan` → `bodyApplied` → 改名/关联）。重新整理的行动使用新的行动 ID，旧提醒被替换，不会重复，也不会把旧行动的完成状态套到新行动上。
4. 预览之后若笔记再被修改（包括 App 内改类型、移除待办），按 ADR 0002 较新的内容获胜：预览标记 `stale`，只能 `discardReorganization`。放弃不释放、不遗忘任何已发送尝试的费用。

用户在 App 内的行动决定此前会把同一笔记所有带结果的任务标为已应用；现在会跳过未应用/已放弃的预览，避免“未应用却显示已应用”。

App：笔记详情“更正转写与重新整理”（`ReorganizeScreen`）。改类型与移除待办沿用既有的“修正类型与行动”页面，均只在本机保存。

## 验证

```sh
flutter test test/processing_recovery_test.dart test/processing_recovery_ui_test.dart
flutter test --timeout 60s
flutter analyze
```

`processing_recovery_test.dart` 覆盖：三次自动重试后手动恢复（含重启）、凭据/余额失败不循环、无效模型结果手动重试、录音分阶段恢复不重传、文档提取失败重试、转写更正与外部修改保护、预览→应用无重复提醒（含重启）、预览后修改只可放弃、重复点击只发送一次。

未验证：真实 OpenRouter 转写/整理与费用、Android/Windows 原生界面、真实崩溃（SIGKILL）下的更正/预览恢复（本票只以重开工作区覆盖）。本机高负载时既有的 `audio_pipeline_ui_test`、`compact_budget_navigation_test`、`document_processing_ui_test`、`reminder_ui_test` 会因固定 100 ms 等待偶发 `pumpAndSettle` 超时，基线提交同样复现，单独运行通过。
