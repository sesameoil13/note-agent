# T02 Android text capture and vault authorization

T02/#3 is **not accepted yet**. On 2026-10-19 the ARM64 release APK compiled successfully and passed signature/alignment checks. Installation, persisted grants across a real reboot, Xiaomi behavior, and Obsidian handoff remain unverified. Compilation and mocked OS responses do not establish any phone result.

## Implemented boundary

The same public `NoteWorkspace` commits original text to private SQLite before publishing ordinary Markdown and the original `.txt` source. `VaultStorage` lets a desktop directory and an Android SAF tree use the same capture, recovery, and template behavior. Desktop callers can keep the T01 `vaultDirectory` argument and `NoteFilePublisher` contract. Android note/source references are opaque `noteagent-vault:` values and are never passed to `File` or `Directory`.

Android uses the system `ACTION_OPEN_DOCUMENT_TREE` picker, takes the returned persistable **read and write** URI grant, and stores the selected tree identity in app preferences. The local database uses the app's private files directory. A missing, moved, or revoked tree returns an authorization message while preserving the selected identity and recoverable local records. Reauthorization of that same tree lets a failed capture retry without another note identity. Cancelling selection keeps the current vault and editor text.

The picker accepts the phone's local shared-storage provider (`com.android.externalstorage.documents`), including an authorized local volume. Cloud document providers are rejected with an explanation because the current Obsidian Android handoff requires a local vault. No all-files, legacy external-storage, or broad storage permission is requested. Choose a new dedicated subdirectory: Android 11+ does not permit granting storage root, Download root, Android/data, or Android/obb through this picker.

`ContentResolver` and `DocumentsContract` handle all tree traversal. The adapter writes a private staged document, closes it, verifies the complete UTF-8 text, checks that the destination is absent or already has identical content, moves it into place, and verifies again. It reports failure rather than claiming a successful export when any step fails. This does not claim filesystem-level atomic replacement or protection against every concurrent external write: SAF operations are provider dependent. Rename/link maintenance uses compare-before-write and a staged backup of the old document, which is resumed on retry. Real provider interruption and concurrent-edit checks remain required.

Obsidian opens with the vault display name and relative note name through its `obsidian://open` URI. The user must first open the **same directory** as an Obsidian vault. Vault names must identify the intended local vault; a URI dispatch alone is not proof that Obsidian opened the correct file or completed Sync.

## Automated evidence

Host tests exercise capture/restart through `NoteWorkspace`, using real SQLite and a mocked **OS method-channel boundary** for SAF. They check the literal ordinary-note template and full original text. The phone-sized app test exercises permission failure, cancelled selection, same-tree reauthorization, and retry of one durable capture while keeping the entered Chinese text. Existing real temporary-directory tests still exercise desktop publication and recovery. These tests do not execute Android Kotlin, a real provider, the system picker, or a device reboot.

- `flutter test`: the current integrated baseline passes 111 tests on the macOS host (2026-10-19), including the Android workspace tests. The local pairing test requires bundled Node on PATH and the pinned `services/pairing` dev dependencies.
- `flutter analyze`: passes.
- The earlier T02 `flutter build macos --debug --no-pub` passed as a desktop compatibility compile; this Android continuation did not rebuild or launch the running Mac app.
- Native Android SAF integration test is prepared at `integration_test/android_vault_test.dart`; its Android APK compilation is checked separately below, and it has **not executed on a device**.
- Native Mac clipboard/picker acceptance was not rerun for this ticket; prior T01 evidence remains separate.

The prepared Android integration test requires `ANDROID_TEST_VAULT_NAME` to start with `NoteAgent-Test-` and checks that the restored vault display name exactly matches that supplied name. This guards the test's vault writes; it does **not** protect the installed App's private data from Flutter installation or cleanup.

It records model, Android release and API read from `Build`, verifies real provider source/Markdown results, and reopens the workspace with the stored grant. The external test-vault files can survive removal of the App while its private history does not. This same-process restore check does not replace the normal-exit/relaunch and physical-reboot steps below.

## Android framework-test installation safety — correction, 2026-10-20

**Do not run `flutter test integration_test/...` against the retained ordinary App identity `dev.noteagent.note_agent` on the user's phone.** Continue acceptance through the installed ordinary App and human-operated system dialogs. The previously documented same-identity framework command is withdrawn; no replacement phone framework run is authorized by this document.

The pinned Flutter 3.47.7 tool defaults `flutter test`'s `uninstall` option to true. Its integration-test cleanup stops and then uninstalls the App, including private SQLite history, preferences and private originals. Omitting `--no-uninstall` therefore does not preserve records merely because the initial installation used `-r`. The earlier framework run used that default; retained exported vault files are separate from the removed private history. Reinstalling the ordinary APK cannot restore the removed private database.

An explicitly disposable framework target must use `--no-uninstall` to suppress **end-of-test cleanup**. That flag is insufficient for a target with retained data: AndroidDevice.installApp still tries uninstall/reinstall when its initial replacement installation fails. This destructive fallback is prohibited for the user's retained App, even with that flag. A future isolated framework workflow needs its own reviewed, distinct application ID and disposable target/data before it is actionable; this repository currently provides no such workflow.

For a separately authorized ordinary App update, use only normal `adb install -r` replacement semantics. Stop on failure and keep the existing installation; do not fall back to uninstall, clear data, a different signing identity, or a framework installer. Keep device identifiers in memory, save raw tool logs privately, and report only a sanitized result. Test-vault guards do not authorize access to personal vaults, microphone use, or system permission changes.

Headless verification at the actual pinned Flutter tool boundary (no phone or microphone): its CLI tests prove default `uninstallApp: true` and explicit `--no-uninstall` → false; its integration-device tests prove cleanup calls uninstall only for true. These are tool behavior checks, not a reproduction on the user's phone or proof of data recovery. The installation fallback is also present in that SDK's AndroidDevice.installApp; suppressing cleanup does not disable it.

## Android compilation — 2026-10-19

The user resumed Android setup and personally completed the interactive SDK agreement/install step. The implementer verified Java 21, the accepted `android-sdk-license` record and all four required installed package manifests before compiling. No license was automatically accepted and no extra SDK package was installed by this implementer.

The current project uses Flutter 3.47.7, Gradle 9.3.1, AGP 9.1.0, Kotlin 2.4.0, compile/target API 36, minimum API 24, and NDK 28.2.13676358. Java/Kotlin bytecode target is 17; the portable JDK is 21.0.12.1. Required packages are platform-tools 37.0.1, platform 36 revision 2, build-tools 36.0.0 and NDK 28.2.13676358. CMake was not required for this build.

The first actual release compile failed because `ContentResolver.MIME_TYPE_DEFAULT` is absent from Android's public SDK. Both SAF text and binary staging now use the equivalent standard `application/octet-stream` string. The same ARM64 release command then passed:

```sh
flutter pub get
flutter build apk --release --target-platform android-arm64
```

Verified release artifact:

- Package `dev.noteagent.note_agent`, version `0.1.0` / code `1`, ARM64 only; 26,385,737 bytes.
- SHA-256 `64dd574cd61a847044cde13bb4f83e15b446e0ea78d2cb62a381cc1976e89272`.
- APK Signature Scheme v2 verification passes. The current generated release configuration uses the **Android Debug development certificate**, so this artifact is for the current device acceptance. Final release signing belongs to T29.
- `zipalign -P 16 -c -v 4` passes. All packaged ELF load segments have at least 16 KiB alignment: PDFium/SQLite 16 KiB; Flutter/application 64 KiB.
- The manifest declares Internet access and an internal non-exported-receiver permission; no broad external-storage permission is present.

The real native SAF test entry point also compiles into an ARM64 debug APK without launching a device:

```sh
flutter build apk --debug --target-platform android-arm64 \
  --target integration_test/android_vault_test.dart \
  --dart-define=ANDROID_TEST_VAULT_NAME=NoteAgent-Test-T02
```

The Android workspace host tests (2) and analyzer pass again after the native compilation fix. The native test APK was compiled only; no integration test has run on an emulator or phone.

The app's actual OS picker, provider writes, device installation, reboot and Obsidian handoff have **not** run. A successful build and valid signature do not satisfy those acceptance gates.

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
