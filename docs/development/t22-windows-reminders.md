# T22 Windows actionable reminders and wake re-check

Issue [#23](https://github.com/sesameoil13/note-agent/issues/23) stays open until real Windows 11 results are recorded; a macOS or Android demonstration does not substitute. Business rules stay in `NoteWorkspace` (T20): Windows implements the same `NotificationPort` + `NotificationInteractionPort` on channel `dev.noteagent/notifications` through the shared Dart `MethodChannelNotifications`.

## Native adapter (`windows/runner/native_notifications.cpp`)

- **Identity without packaging:** on every start, before any window, the runner writes per-user keys only: `HKCU\Software\Classes\AppUserModelId\dev.noteagent.workspace` (`DisplayName`, `CustomActivator`) and `HKCU\Software\Classes\CLSID\{CBF85C56-35BE-4A74-94AF-61ED4CCDBA26}\LocalServer32` (`"<exe>" -ToastActivated`), sets the process AppUserModelID and registers the COM toast activator (`INotificationActivationCallback`). No machine-wide setting is touched.
- **Toasts:** C++/WinRT `ToastNotifier`. Future reminders are `ScheduledToastNotification`s held by Windows, so they survive normal exit and the App not running; due/immediate ones use `Show`. `actionReminder` toasts carry 完成 / 稍后提醒 buttons (background activation); the body opens the note. A reschedule removes the previous toast with the same tag first. Long revisioned ids map to a 16-hex FNV-1a tag; `accepted.txt` keeps tag → id.
- **Durable responses:** Windows calls the activator in the running App, or starts the App with `-ToastActivated` (window minimized, not focused) and then calls it. The activator validates the arguments, appends the response to `%LOCALAPPDATA%\dev.noteagent\notifications\interactions.txt` and flushes before signalling `interactionAvailable`. `takeInteractions(kind, vault)` drains matching records with an atomic rewrite, so responses survive the App closing straight after. The workspace then applies T20 rules: stale lifecycle, already-completed and repeated responses are ignored; snooze creates a new revision (as on macOS; Android's native re-arm is not used).
- **Inspect:** permission from `ToastNotifier.Setting` (`Enabled` → allowed; disabled for user/app/group policy → denied), pending from scheduled toasts, delivered from Action Center history, accepted from the store. A reminder the OS lost but still in the future is rescheduled by the existing reconcile. `exactTiming` stays true: Windows has no exact-alarm grant, but it does not wake a sleeping PC for a toast.
- **Honest denial:** Windows never prompts desktop apps. The explicit "允许系统通知" button opens `ms-settings:notifications` (unless group policy disables it) and returns the real state; plans stay in the App and show as blocked. Focus assist / Do not disturb cannot be read through this API and is not reported.
- **Re-check triggers:** app resume (existing), `WM_POWERBROADCAST/PBT_APMRESUMEAUTOMATIC` → `systemResumed`, and `NotifyNetworkConnectivityHintChange` (loaded dynamically; Windows 10 2004+) on regaining internet → `networkAvailable`. Dart treats both like Android's network return: reconcile reminders, then sync to-dos.

## Headless evidence (macOS host)

- `test/notification_platform_test.dart`: `systemResumed` reaches the re-check stream (red seen first); existing kind/vault draining and network tests still pass.
- `flutter analyze` clean; full `flutter test` result recorded in the branch report.
- Windows CI: not yet run (workflow not registered on `main`); see t03-validation.md. CI can at most prove compilation/linking; it cannot show a toast.

## Requires real Windows 11 desktop acceptance

- [ ] Toast appears at the planned time with both buttons; body click opens the note.
- [ ] 完成 and 稍后提醒 with the App in front, minimized, and fully closed (App starts minimized and applies them); repeated clicks on an old toast do nothing more.
- [ ] Normal exit before the time, reboot, sleep across the time then wake (late toast and re-check), network off/on.
- [ ] Notifications off for the App / globally: blocked status, the button opens Settings, re-enabling then resume reschedules.
- [ ] Focus assist behaviour recorded as an OS limit.
