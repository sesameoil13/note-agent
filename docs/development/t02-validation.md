# T02 Android text capture and vault authorization

T02/#3 is **not accepted yet**. Android source and host-side behavior coverage are prepared; APK compilation, installation, persisted grants across a real reboot, Xiaomi behavior, and Obsidian handoff have not been run. Mocked OS responses do not establish any phone result.

## Implemented boundary

The same public `NoteWorkspace` commits original text to private SQLite before publishing ordinary Markdown and the original `.txt` source. `VaultStorage` lets a desktop directory and an Android SAF tree use the same capture, recovery, and template behavior. Desktop callers can keep the T01 `vaultDirectory` argument and `NoteFilePublisher` contract. Android note/source references are opaque `noteagent-vault:` values and are never passed to `File` or `Directory`.

Android uses the system `ACTION_OPEN_DOCUMENT_TREE` picker, takes the returned persistable **read and write** URI grant, and stores the selected tree identity in app preferences. The local database uses the app's private files directory. A missing, moved, or revoked tree returns an authorization message while preserving the selected identity and recoverable local records. Reauthorization of that same tree lets a failed capture retry without another note identity. Cancelling selection keeps the current vault and editor text.

The picker accepts the phone's local shared-storage provider (`com.android.externalstorage.documents`), including an authorized local volume. Cloud document providers are rejected with an explanation because the current Obsidian Android handoff requires a local vault. No all-files, legacy external-storage, or broad storage permission is requested. Choose a new dedicated subdirectory: Android 11+ does not permit granting storage root, Download root, Android/data, or Android/obb through this picker.

`ContentResolver` and `DocumentsContract` handle all tree traversal. The adapter writes a private staged document, closes it, verifies the complete UTF-8 text, checks that the destination is absent or already has identical content, moves it into place, and verifies again. It reports failure rather than claiming a successful export when any step fails. This does not claim filesystem-level atomic replacement or protection against every concurrent external write: SAF operations are provider dependent. Rename/link maintenance uses compare-before-write and a staged backup of the old document, which is resumed on retry. Real provider interruption and concurrent-edit checks remain required.

Obsidian opens with the vault display name and relative note name through its `obsidian://open` URI. The user must first open the **same directory** as an Obsidian vault. Vault names must identify the intended local vault; a URI dispatch alone is not proof that Obsidian opened the correct file or completed Sync.

## Automated evidence

Host tests exercise capture/restart through `NoteWorkspace`, using real SQLite and a mocked **OS method-channel boundary** for SAF. They check the literal ordinary-note template and full original text. The phone-sized app test exercises permission failure, cancelled selection, same-tree reauthorization, and retry of one durable capture while keeping the entered Chinese text. Existing real temporary-directory tests still exercise desktop publication and recovery. These tests do not execute Android Kotlin, a real provider, the system picker, or a device reboot.

- `flutter test`: 7 tests pass on the macOS host.
- `flutter analyze`: passes.
- `flutter build macos --debug --no-pub`: passes as a desktop compatibility compile; no app was launched.
- Native Android SAF integration test is prepared at `integration_test/android_vault_test.dart`, **not executed**.
- Native Mac clipboard/picker acceptance was not rerun for this ticket; prior T01 evidence remains separate.

The prepared Android integration test refuses a vault whose supplied name does not start with `NoteAgent-Test-`. After selecting that new directory in the installed app, run it on the actual connected phone with its exact name:

```sh
flutter test integration_test/android_vault_test.dart -d <actual-device-id> \
  --dart-define=ANDROID_TEST_VAULT_NAME=NoteAgent-Test-T02
```

It records model, Android release and API read from `Build`, verifies real provider source/Markdown results, and reopens the workspace with the stored grant. It leaves its distinct acceptance note/source in that dedicated vault for inspection. This same-process restore check does not replace the normal-exit/relaunch and physical-reboot steps below.

## Build prerequisites still open

The user explicitly deferred Android SDK setup/build work. Do not start package installation, license review prompts, or device/build work until that work is resumed.

The Android scaffold was generated from Flutter 3.47.7, not guessed from an old template. It selects Gradle 9.3.1, AGP 9.1.0, Kotlin 2.4.0, compile/target API 36, minimum API 24, and NDK 28.2.13676358. Java/Kotlin bytecode target is 17; the staged portable JDK 21 is suitable for Gradle. No additional Flutter plugins were added.

At preparation time the portable JDK and command-line tool files were staged, but Android SDK packages and license acceptance were absent. No SDK license was accepted, no `sdkmanager` command was executed, no APK was built, and no phone was connected by this implementer. The responsible user must review the official SDK terms and make the interactive license decision before package installation. Do not pipe automated approval or fabricate accepted-license files.

Required package selection from the actual template and native dependency needs:

```sh
sdkmanager --sdk_root="$ANDROID_HOME" \
  "platform-tools" "platforms;android-36" "build-tools;36.0.0" \
  "ndk;28.2.13676358" "cmake;3.22.1"
flutter pub get
flutter build apk --debug
```

This is the remaining setup recipe, **not an executed or successful build**. Gradle/Maven/pub downloads are also required. The generated release configuration currently uses a development debug key; final release signing/installation belongs to platform delivery, not this source-preparation claim.

## Required Xiaomi 17 Pro Max acceptance

Use only a newly created `NoteAgent-Test-T02` local directory and the same directory opened in Obsidian. The old vault and remote Sync slot remain off limits.

- [ ] Build and install the actual APK, recording package/version and exact phone identity/Android release/API shown by the app.
- [ ] Use the actual system directory picker and accept read/write for that test directory. Verify no broad storage-permission request.
- [ ] Input/paste multiline Chinese text, save, inspect exactly 正文 → 关联 → 来源 with no summary/properties and time immediately after source. Open full original in the app and inspect the real `.txt` and Markdown in the vault.
- [ ] Open the corresponding note in Obsidian and verify the source link there. No Sync completion claim without separate evidence.
- [ ] Exit normally, relaunch, and inspect the same note, source, and restored authorization; then physically reboot and repeat without reselecting the vault.
- [ ] Cancel directory selection while a draft is entered and confirm it remains intact.
- [ ] Revoke authorization or move the dedicated test directory. Confirm accurate guidance, no false saved status, and existing local original remains readable. Enter/save text in the unavailable state and confirm input remains. Reauthorize the same tree and retry: exactly one capture/source/note.
- [ ] Interrupt provider publication and retry, checking no visible partial note and no unrelated note replacement. Exercise a same-name note and a non-writable destination.
- [ ] Check phone layout with the keyboard open, clear readable Chinese text, recent-record selection, source dialog, and error/retry actions.

## Primary references

- [Android SAF document/tree access, persisted permissions, and restrictions](https://developer.android.com/training/data-storage/shared/documents-files).
- [DocumentsContract operations](https://developer.android.com/reference/android/provider/DocumentsContract).
- [Obsidian URI](https://help.obsidian.md/uri).
- [Flutter Android setup](https://docs.flutter.dev/platform-integration/android/setup) and [SDK manager](https://developer.android.com/tools/sdkmanager).
