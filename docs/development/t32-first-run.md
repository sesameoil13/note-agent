# T32 First-run step sequence (issue #33)

Replaces the setup list on first open with one modal per step. The list stays as the
设置 page (`lib/setup_screen.dart`) for later changes and re-checks.

## Pieces

- **Step model** (`lib/first_run.dart`): `nextFirstRunStep(answers, facts)` derives the next
  modal from what the App observes (`FirstRunFacts`: key, device identity, vault, backup
  ready, the four Obsidian reports) and the user's answers (`FirstRunAnswers`: started,
  first device, old vault, notification request, 稍后 set, finished). Quitting mid-way
  resumes at the right modal because nothing else decides the step.
  `outstandingFirstRunSteps` feeds the banner; `firstRunAtLaunch` marks an install that had
  a vault, an expired vault grant or a device identity as finished, with no banner.
- **Modals** (`lib/first_run_flow.dart`): `showFirstRun` opens a dialog (full screen under
  600 px) that leaves only through 开始收集. `PopScope` blocks system Back. The flow reaches
  OpenRouter and pairing through `FirstRunServices`; `ConnectionFirstRunServices` adapts
  `WorkspaceConnection` (pairing operations are extension methods, so tests fake the
  interface instead).
- **Persistence**: `WorkspaceConnection.loadFirstRun` / `saveFirstRun` keep the answers in
  the device's credential record (`firstRun`): they are per device and exist before a vault
  is chosen. An answer is saved before the flow moves on.
- **Launch** (`lib/main.dart`): `_startFirstRun` runs after `restoreLocation`; a locked
  keychain skips the sequence for this launch. The banner "还有 N 步未完成 · 继续" reopens
  at the first unfinished step.
- **Shared with 设置**: `compareOldVaultBackup` and `confirmRemoteSlotSwitch` in
  `lib/setup_screen.dart`.

## Rules kept

- Only the vault step has no 稍后. Cancelling the picker stays on the step with a message.
- Obsidian checks stay "你已核对"; the notification step requests permission and does not
  mark the recording or reminder tests done.
- The first device needs the 首次启用码 and a device name to register; a key saved before a
  failed registration is not asked for again.
- A paired device checks the key it received; a failed check stays on the join modal.
  稍后 there leaves a pending request in place.
- The backup modal moves on only when the backup is ready (compared or reported, plus the
  local import copy kept) and the user taps 继续; the remote-slot switch stays separate.

## Tests

- `test/first_run_test.dart`: branches, 稍后, banner, reopen, upgrade rule, JSON.
- `test/first_run_flow_test.dart`: both device branches, failed registration, backup
  comparison (mocked folder picker), 稍后 throughout, a failed save, a failed key check,
  system Back and a cancelled picker.
- `test/first_run_launch_test.dart`: new install, existing install, resume, banner.

## Not verified

Real folder pickers, the macOS secure-input sheets inside a dialog, system permission
dialogs, and pairing against the deployed service.
