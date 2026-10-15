# T03 Windows text collection — acceptance pending

Issue [#4](https://github.com/sesameoil13/note-agent/issues/4) remains open. Windows runner/adapters are implemented in source; no Windows build or Windows 11 runtime result has been obtained. Passing macOS tests does not satisfy this ticket's platform acceptance.

## Implemented boundaries

- Windows' `IFileOpenDialog` selects an existing filesystem folder. Cancellation leaves the previous selection intact. No vault is discovered automatically.
- The app records only the selected path under `HKCU\Software\NoteAgent\VaultDirectory`. This is a desktop filesystem selection, not a sandbox permission grant. Windows ACLs still apply; unavailable saved folders return a visible error and can be selected again.
- Private local state lives under `%LOCALAPPDATA%\dev.noteagent\workspace`; the selected vault holds the same ordinary-note Markdown and original text as on macOS.
- File publication flushes a private staging file then calls Unicode `MoveFileExW` without replacement or cross-volume-copy flags. An existing destination remains untouched; retry checks a previously committed file's contents. macOS continues using its existing POSIX publisher.
- Obsidian handoff resolves existing file and vault handles, checks that the file lies inside that vault, percent-encodes the Unicode path, and opens the `obsidian:` URI through `ShellExecuteExW`. A missing handler returns app feedback.

The native clipboard integration test uses Ctrl+V on Windows and Cmd+V on macOS. Its generated key events remain framework-driven integration coverage; they do not replace physical keyboard/IME acceptance.

## Evidence obtained on 2026-10-15

- macOS ARM64: `flutter test` passed all 5 existing workspace/widget tests; `flutter analyze` passed. These cover source/template persistence, failure and retry, interruption recovery, existing-file preservation, and the visible capture flow on the host platform.
- A Windows platform integration test was written before its native adapter. Attempting `flutter test integration_test/windows_platform_test.dart -d windows` could not start because this macOS host has no Windows Flutter device. No behavioral red/green result is claimed for it.
- Read-only Parallels inventory identified an existing **stopped Windows 11 ARM64 VM**, with 4 CPUs and 6GB RAM. The root coordinator authorized a CLI boot and task-limited guest inspection. Boot failed because the Parallels activation period had expired. No guest command, installation, license change, or purchase was performed.
- `.github/workflows/windows-build.yml` is prepared for review, with `workflow_dispatch` as its only trigger. It has not been dispatched. It uses one `windows-2025` x64 job with a 30-minute limit, `contents: read`, official actions pinned to commit hashes, checksum-pinned official Flutter 3.47.7, and a release-only ZIP capped at 100 MiB and retained for one day. This runner can validate compilation/tests; it cannot establish Windows 11 desktop acceptance.

## Remaining native gate

Use an available, appropriately licensed Windows 11 machine and a fresh local test vault. Record the actual OS build and processor architecture. Install/configure Flutter 3.47.7 and Visual Studio's required Windows desktop C++ toolchain according to [Flutter's Windows setup instructions](https://docs.flutter.dev/platform-integration/windows/setup); account or license prompts require the machine owner.

```powershell
flutter pub get --enforce-lockfile
flutter test --no-pub
flutter analyze --no-pub
flutter build windows --release --no-pub
flutter test integration_test/windows_platform_test.dart -d windows
flutter test integration_test/native_clipboard_test.dart -d windows
```

Coordinate native integration-test launches with the session owner, since they open a window and the clipboard test temporarily writes the system clipboard. Open the entire release bundle's `note_agent.exe` on that Windows 11 machine, then record:

1. System folder picker cancellation and selection of a new test vault; no existing user vault is used.
2. Physical Chinese input and Ctrl+V, saving, clear 正文 → 关联 → 来源 ordering, exact original text, and timestamps after the source link.
3. A controlled write failure preserves local original text and shows a useful error; retry after correcting the test folder succeeds without duplicate records or replacement of unrelated files.
4. Normal quit, process exit, relaunch, restored selected directory, persisted record, original source and template. A reopened in-process workspace alone is insufficient evidence for this step.
5. Real Obsidian installed and the same test directory registered locally; the button opens the corresponding Unicode/space-containing note. Also verify absent-handler feedback on a suitable clean test setup.
6. Moved/unavailable directory feedback and recovery through the picker. Record any remaining permission-edge gaps under the final platform/setup tasks.

Only after real Windows results are recorded should the three issue acceptance criteria be considered for completion. An x64 hosted build does not validate ARM64 execution in the unavailable VM.

## Primary references

- [Windows folder-dialog options](https://learn.microsoft.com/en-us/windows/win32/api/shobjidl_core/ne-shobjidl_core-_fileopendialogoptions)
- [MoveFileExW flags and failure semantics](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-movefileexw)
- [ShellExecuteExW](https://learn.microsoft.com/en-us/windows/win32/api/shellapi/nf-shellapi-shellexecuteexw)
- [Official Flutter Windows release manifest](https://storage.googleapis.com/flutter_infra_release/releases/releases_windows.json)
