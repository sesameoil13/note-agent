# T21：Android 可操作提醒及重启恢复

本票把 T20 的提醒生命周期接到 Android。业务规则仍只在 `NoteWorkspace`：Android 适配器实现与 macOS 相同的 `NotificationPort` + `NotificationInteractionPort`（通道 `dev.noteagent/notifications`，Dart 侧共用 `MethodChannelNotifications`）。没有云端调用或付费请求。

## 原生结构（`android/.../NativeNotifications.kt`）

- `ReminderStore`：SharedPreferences 中持久保存已接受的计划、已送达标识和待处理的通知操作（`commit()` 同步写入）。闹钟由它统一布设，因此可在重启或强制停止后重新布设。
- `ReminderReceiver`（不导出）：闹钟到点发通知；“完成”“稍后提醒”按钮先把操作持久记录，再关闭通知。App 未运行时操作不会丢失，下次启动、回到前台或收到信号时由 workspace 按 T20 规则处理（旧生命周期、已完成、重复投递一律忽略）。
- “稍后提醒”在 App 未运行时也必须生效：接收器按通知载荷中的 `snoozeMinutes`（来自本机默认延后时长）以**同一通知标识**重新布设闹钟，并在操作记录中写入 `snoozedUntilMs`。workspace 之后采用这个时间而不再新排一次，避免同一事项第二次响铃。App 内或 macOS 的延后仍按 T20 生成新标识。
- 点按通知正文经 `MainActivity`（singleTop）打开对应笔记。因 Activity 是导出的，此入口只记录“打开”，绝不记录完成或延后。
- `ReminderBootReceiver`（导出，仅系统广播）：`BOOT_COMPLETED`、`MY_PACKAGE_REPLACED` 时重新布设；获得精确闹钟授权变化时全部重新布设。已过时间且未送达的提醒在恢复时**立即补发**，即迟到送达，不记作准时。
- 每次 `inspect`（启动、回到前台、联网、手动“重新核对”）先恢复丢失的闹钟：强制停止会清除闹钟及其 PendingIntent，以 `FLAG_NO_CREATE` 判断缺失。
- 联网恢复：App 运行时注册默认网络回调，发出 `networkAvailable`，App 随即核对提醒（与回到前台相同）。

## 权限与降级

- 通知权限（API 33+ `POST_NOTIFICATIONS`）只在“允许系统通知”按钮下请求；系统不再弹窗时打开本 App 的通知设置页。通知渠道被关闭也视为未允许，计划保留在 App 内并显示为受阻。
- 精确闹钟：`SCHEDULE_EXACT_ALARM`。未授权时仍以 `setAndAllowWhileIdle` 安排，快照返回 `exactTiming: false`，提醒设置页明确显示“精确闹钟未允许：提醒仍已安排，但系统可能推迟送达”。通知已允许时再点“允许系统通知”会打开系统“闹钟和提醒”页面。未使用 `USE_EXACT_ALARM`。
- 强制停止：Android 在用户再次打开 App 前不会投递闹钟或开机广播。本 App 不承诺这期间准时提醒；再次打开时补发已过时间的提醒。
- 系统设置未被本实现修改；只在用户点按后打开系统设置页面。

## 已验证（仅主机与编译）

- 新增 `test/android_reminder_test.dart` 4 项、`test/android_reminder_ui_test.dart` 1 项、`notification_platform_test.dart` 1 项：精确闹钟降级状态、系统丢失闹钟后以同一标识重排、载荷携带延后时长、采用原生已重布的延后且不二次排程、适配器解析 `exactTiming` 与联网信号。
- `flutter analyze` 无问题；`flutter test` 全部通过（高负载并行时，基线上本就存在的 `document_processing_ui_test` 的 `pumpAndSettle` 超时除外，单独运行通过与否与本票无关）。
- `flutter build apk --debug --target-platform android-arm64` 编译通过（需先 `source tools/android-env.sh`）。

## 尚需真机（Xiaomi）验收

以下均**未**在设备上运行：

- [ ] 首次请求通知权限弹窗、拒绝后再次点按打开设置页；渠道关闭后显示受阻。
- [ ] 授予／撤回“闹钟和提醒”后状态文字变化，授予后已有提醒改为精确布设。
- [ ] 锁屏、Doze 下准时送达；通知上“完成”“稍后提醒”按钮在 App 前台、后台、被划掉进程时均有效，App 启动后笔记勾选与延后时间一致，不重复响铃。
- [ ] 重启后提醒恢复（MIUI 需允许“自启动”，否则收不到 `BOOT_COMPLETED`，只能在下次打开 App 时补发）；省电策略“无限制”与默认策略下的差异。
- [ ] 强制停止后不送达、再次打开 App 后补发；断网→联网后核对。
- [ ] 小图标使用启动器图标，部分系统可能显示为纯色块，需目测确认。
