# T28 First-run guide and old-vault switch (issue #29)

Stories 4–9, 38, 39, 83–85, 109. Builds on the existing guide (`lib/setup_screen.dart`,
`lib/workspace_setup.dart`, merge 1e887de) rather than replacing it.

## What the guide does

- **Progress summary** (`describeSetup` in `lib/workspace_setup.dart`): one row per step
  (AI connection, device pairing, local vault, recording/notifications, Obsidian & Sync,
  old-vault backup) with one of four evidence levels:
  - `App 已验证`: the App holds its own proof: a successful OpenRouter check this run,
    a registered device identity, an authorized vault, or its own backup comparison.
  - `你已核对`: the user's report about another app or the system. Obsidian Sync,
    hidden properties, other-file-type sync, microphone and notification tests can never be
    more than this.
  - `需要处理`: a saved key that is unchecked or failed, or an expired vault grant
    (`authorizationError` from `restoreLocation`, now kept in `main.dart` and passed to the guide).
  - `未完成`.
- **Read-only backup comparison** (`lib/backup_check.dart`,
  `NoteWorkspace.checkOldVaultBackup`): the user picks the old vault and its backup
  (macOS `chooseFolder` channel method: a one-off `NSOpenPanel`, never bookmarked or
  activated as the vault). The App lists files and sizes only and reports counts, bytes,
  whether `.obsidian` is included, and missing or size-mismatched files. It refuses when
  the backup lies inside the old vault, either folder overlaps the current sync vault, or
  the old vault is empty. A complete result records `backupVerifiedByApp`. An incomplete
  or refused result withdraws that record, the user's `backupComplete` report, and any
  remote-slot consent.
- **Remote slot consent** still needs a backup (App-verified or user-reported) **and** the
  user's report that the old vault is kept as a local import copy, then a separate dialog.
  The App never operates the remote slot. The user does that in Obsidian and reports it.
- Prepaid balance (unknown, held in the OpenRouter account) is shown apart from the shared
  monthly CNY limit and spend. Auto top-up stays off and the App never tops up.

## Safety

The App never discovers, switches or modifies an old vault. All tests use
`Directory.systemTemp` folders, and the comparison tests assert both folders are
byte-identical afterwards.

## Tests

- `test/backup_check_test.dart`: workspace seam (complete, incomplete with invalidation,
  refused locations).
- `test/setup_progress_test.dart`: evidence levels, never `appVerified` for Sync/permissions.
- `test/setup_guide_ui_test.dart`: summary rendering, picked-folder comparison, and
  cancelling a pick (mocked `dev.noteagent/workspace` channel).
- `test/setup_ui_test.dart`: the expired-grant test now also expects `需要处理`.

## Not verified

- The real `NSOpenPanel` pick and sandbox read access to the chosen folders (only
  `flutter build macos --debug` was run).
- Android/Windows offer no folder comparison. The guide says so and keeps the manual check.
- Several timing-sensitive UI tests (`reminder_ui`, `compact_budget_navigation`,
  `document_processing_ui`, `note_associations_ui`) fail under heavy machine load
  (load average above 40). They fail the same way on the untouched base checkout.
